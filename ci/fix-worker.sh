#!/usr/bin/env bash
# forcicd auto-fix worker — runs ONE issue-driven fix attempt.
#
# Invoked by the dispatcher inside a `screen` session named after
# the request (so you can `screen -r fix-<repo>-<n>` on the VM to
# watch live). It:
#   1. clones the repo into a throwaway workspace
#   2. pulls the issue title/body as the task brief
#   3. launches a throwaway container and runs your Claude client
#      against the brief (the CLAUDE_CMD hook — you wire in your
#      subscription/auth), followed by a build cycle
#   4. streams everything to a transcript
#   5. posts a summary + transcript tail back to the issue
#   6. tears the container + workspace down
#
# Config: /etc/forcicd/fix.env (see fix.env.sample). The Claude
# invocation is intentionally a hook — set CLAUDE_CMD there.
#
# Args: <owner/repo> <issue-number> <session-name>

set -uo pipefail

REPO="${1:?usage: fix-worker.sh <owner/repo> <issue#> <session>}"
NUMBER="${2:?missing issue number}"
SESSION="${3:?missing session name}"

# ---- config -------------------------------------------------------
ENVF=/etc/forcicd/fix.env
[[ -f "${ENVF}" ]] && source "${ENVF}"
: "${GH_TOKEN_FILE:=/etc/forcicd/github-token}"
: "${WORKROOT:=/var/lib/forcicd/fix-workspaces}"
: "${LOGROOT:=/var/lib/forcicd/fix-logs}"
: "${LOCAL_REGISTRY:=forcicd.g8.lo:5000}"
# Container image the fix runs inside. Default to the ubuntu
# toolchain runner image (has rust/go/C/etc). Override per need.
: "${FIX_IMAGE:=${LOCAL_REGISTRY}/forcicd-runner-ubuntu22:latest}"
# THE HOOK: how to invoke your Claude client inside the container.
# It receives the task brief on stdin and at $TASK_FILE. You supply
# the binary + auth (mounted via FIX_MOUNTS / baked into FIX_IMAGE).
# Default is a no-op stub that just records that no client is wired.
: "${CLAUDE_CMD:=}"
# Extra `docker run` args to mount your claude binary/config/creds,
# e.g. "-v /opt/claude:/opt/claude:ro -v /etc/forcicd/claude:/root/.claude:ro"
: "${FIX_MOUNTS:=}"
# Build cycle to run after the fix attempt (auto-detected if empty).
: "${BUILD_CMD:=}"
# If true, push the fix to a branch and open a PR instead of just
# commenting. Default: comment-only (safe; you review).
: "${FIX_PUSH:=false}"
: "${FIX_MAX_MINUTES:=30}"

TOKEN=$(cat "${GH_TOKEN_FILE}" 2>/dev/null || true)
[[ -n "${TOKEN}" ]] || { echo "no github token at ${GH_TOKEN_FILE}" >&2; exit 3; }

NAME="${REPO##*/}"
WORK="${WORKROOT}/${SESSION}"
LOG="${LOGROOT}/${SESSION}.log"
install -d -m 0755 "${WORKROOT}" "${LOGROOT}"
rm -rf "${WORK}"; install -d -m 0755 "${WORK}"

exec > >(tee -a "${LOG}") 2>&1
echo "=== forcicd auto-fix worker ==="
echo "repo=${REPO} issue=#${NUMBER} session=${SESSION} image=${FIX_IMAGE}"
echo "started=$(date -u +%FT%TZ)"

# ---- 1. clone -----------------------------------------------------
echo "==> cloning ${REPO}"
git clone --depth 50 \
    "https://x-access-token:${TOKEN}@github.com/${REPO}.git" \
    "${WORK}/repo" || { echo "clone failed"; exit 4; }

# ---- 2. fetch the issue as the task brief -------------------------
echo "==> fetching issue #${NUMBER}"
ISSUE_JSON=$(curl -sS -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/issues/${NUMBER}")
TASK_FILE="${WORK}/TASK.md"
python3 - "$ISSUE_JSON" > "${TASK_FILE}" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
print(f"# Fix issue #{d.get('number')}: {d.get('title','')}\n")
print(d.get("body") or "(no description)")
print("\n---\n")
print("You are working in a clone of this repo. Diagnose the failure, "
      "make the minimal correct fix, and run the build cycle until it "
      "passes. Do not push; leave your changes in the working tree.")
PY
echo "--- task brief ---"; cat "${TASK_FILE}"; echo "------------------"

# ---- 3. build cycle auto-detect -----------------------------------
if [[ -z "${BUILD_CMD}" ]]; then
    if   [[ -f "${WORK}/repo/Cargo.toml" ]]; then BUILD_CMD="cargo build --all && cargo test --all --no-fail-fast"
    elif [[ -f "${WORK}/repo/go.mod"     ]]; then BUILD_CMD="go build ./... && go test ./..."
    elif [[ -f "${WORK}/repo/Makefile"   ]]; then BUILD_CMD="make"
    else BUILD_CMD="echo '(no build system detected)'"; fi
fi
echo "==> build cmd: ${BUILD_CMD}"

# ---- 4. run the fix attempt in a throwaway container --------------
echo "==> launching throwaway container ${SESSION}"
sudo docker pull "${FIX_IMAGE}" >/dev/null 2>&1 || true

if [[ -z "${CLAUDE_CMD}" ]]; then
    echo "!! CLAUDE_CMD not set in ${ENVF} — running build-only (no fix attempt)."
    echo "!! Wire your Claude client there to enable autonomous fixing."
    INNER="cd /work && ${BUILD_CMD}"
else
    # The hook: your Claude client gets the brief on stdin + at
    # /work/TASK.md, attempts the fix, then we run the build cycle.
    INNER="cd /work && ${CLAUDE_CMD} < /work/TASK.md ; echo '=== build cycle ===' ; ${BUILD_CMD}"
fi

set +e
timeout "${FIX_MAX_MINUTES}m" sudo docker run --rm --name "${SESSION}" \
    --security-opt seccomp=unconfined \
    --network forcicd_default \
    -v "${WORK}/repo:/work" \
    -v "${TASK_FILE}:/work/TASK.md:ro" \
    ${FIX_MOUNTS} \
    "${FIX_IMAGE}" \
    bash -lc "${INNER}"
RC=$?
set -e
echo "==> container exited rc=${RC}"

# ---- 5. capture diff + result -------------------------------------
DIFF=$(cd "${WORK}/repo" && git diff --stat && echo && git diff | head -400)
VERDICT=$([[ ${RC} -eq 0 ]] && echo "✅ build passed after fix attempt" \
                            || echo "❌ build still failing (rc=${RC})")

# ---- 6. post back to the issue ------------------------------------
echo "==> commenting on ${REPO}#${NUMBER}"
COMMENT=$(python3 - <<PY
import json
verdict = """${VERDICT}"""
diff = """$(printf '%s' "${DIFF}" | sed 's/"""/\\"\\"\\"/g')"""
tail = open("${LOG}").read()[-4000:]
body = (
    f"### forcicd auto-fix attempt — \`${SESSION}\`\n\n"
    f"{verdict}\n\n"
    f"<details><summary>proposed diff</summary>\n\n\`\`\`diff\n{diff}\n\`\`\`\n</details>\n\n"
    f"<details><summary>transcript tail</summary>\n\n\`\`\`\n{tail}\n\`\`\`\n</details>\n\n"
    f"_Ran in throwaway container; workspace discarded. "
    f"Attach live: \`screen -r ${SESSION}\` on forcicd.g8.lo while running._"
)
print(json.dumps({"body": body}))
PY
)
curl -sS -X POST -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/issues/${NUMBER}/comments" \
    -d "${COMMENT}" -o /dev/null -w "  comment HTTP %{http_code}\n"

# ---- 7. optional: push fix to a branch + PR -----------------------
if [[ "${FIX_PUSH}" == "true" && ${RC} -eq 0 ]]; then
    BR="forcicd/fix-${NUMBER}"
    ( cd "${WORK}/repo"
      git config user.name forcicd; git config user.email ci@g8.lo
      git checkout -b "${BR}"
      git commit -am "fix: auto-fix for #${NUMBER} (forcicd)"
      git push "https://x-access-token:${TOKEN}@github.com/${REPO}.git" "${BR}" )
    curl -sS -X POST -H "Authorization: Bearer ${TOKEN}" \
        "https://api.github.com/repos/${REPO}/pulls" \
        -d "{\"title\":\"forcicd auto-fix for #${NUMBER}\",\"head\":\"${BR}\",\"base\":\"main\",\"body\":\"Closes #${NUMBER}\"}" \
        -o /dev/null -w "  PR HTTP %{http_code}\n"
fi

# ---- 8. teardown --------------------------------------------------
rm -rf "${WORK}"
echo "done=$(date -u +%FT%TZ) rc=${RC}"
