#!/usr/bin/env bash
# forcicd auto-fix worker — one issue-driven session.
#
# Modes:
#   fixit       autonomous. Claude fixes the issue with no turn
#               limit, writes up what it did, we run the build
#               cycle, post the writeup to the issue, and — if the
#               build goes green — comment + CLOSE the issue (and
#               optionally open a PR with the fix).
#   interactive spin the throwaway env with the repo + claude
#               ready, leave a screen session running a shell, post
#               the attach instructions to the issue. No teardown
#               until you end the session.
#
# Backends (FIX_BACKEND): `docker` (default, runs on this VM) or
# `lxc` (throwaway CT on pve.g8.lo — see fix.env.sample).
#
# Runs inside a screen session named <session> (so `sudo screen -r
# <session>` on the VM attaches live). Config: /etc/forcicd/fix.env.
#
# Args: <owner/repo> <issue#> <session> <mode>

set -uo pipefail

REPO="${1:?usage: fix-worker.sh <owner/repo> <issue#> <session> <mode>}"
NUMBER="${2:?missing issue number}"
SESSION="${3:?missing session name}"
MODE="${4:-fixit}"

# ---- config -------------------------------------------------------
ENVF=/etc/forcicd/fix.env
[[ -f "${ENVF}" ]] && source "${ENVF}"
: "${GH_TOKEN_FILE:=/etc/forcicd/github-token}"
: "${WORKROOT:=/var/lib/forcicd/fix-workspaces}"
: "${LOGROOT:=/var/lib/forcicd/fix-logs}"
: "${LOCAL_REGISTRY:=forcicd.g8.lo:5000}"
: "${FIX_BACKEND:=docker}"
: "${FIX_IMAGE:=${LOCAL_REGISTRY}/forcicd-runner-ubuntu22:latest}"
: "${FIX_LXC_TEMPLATE:=}"          # CT id/name to clone for lxc backend
: "${PVE_HOST:=root@pve.g8.lo}"
: "${CLAUDE_CMD:=}"                # THE HOOK — your claude client
: "${FIX_MOUNTS:=}"
: "${BUILD_CMD:=}"
: "${FIX_PUSH:=false}"
: "${FIX_MAX_MINUTES:=120}"        # fixit is unlimited-ish; cap for safety

TOKEN=$(cat "${GH_TOKEN_FILE}" 2>/dev/null || true)
[[ -n "${TOKEN}" ]] || { echo "no github token at ${GH_TOKEN_FILE}" >&2; exit 3; }

NAME="${REPO##*/}"
WORK="${WORKROOT}/${SESSION}"
LOG="${LOGROOT}/${SESSION}.log"
install -d -m 0755 "${WORKROOT}" "${LOGROOT}"
rm -rf "${WORK}"; install -d -m 0755 "${WORK}"
exec > >(tee -a "${LOG}") 2>&1

api() {  # api METHOD PATH [JSON]
    local m="$1" p="$2" d="${3:-}"
    if [[ -n "${d}" ]]; then
        curl -sS -X "${m}" -H "Authorization: Bearer ${TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com${p}" -d "${d}"
    else
        curl -sS -X "${m}" -H "Authorization: Bearer ${TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com${p}"
    fi
}
comment() {  # comment <body-file>
    local body; body=$(python3 -c 'import json,sys; print(json.dumps({"body": open(sys.argv[1]).read()}))' "$1")
    api POST "/repos/${REPO}/issues/${NUMBER}/comments" "${body}" \
        -o /dev/null -w "  comment HTTP %{http_code}\n" 2>/dev/null \
      || curl -sS -X POST -H "Authorization: Bearer ${TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${REPO}/issues/${NUMBER}/comments" \
            -d "${body}" -o /dev/null -w "  comment HTTP %{http_code}\n"
}

echo "=== forcicd ${MODE} worker ==="
echo "repo=${REPO} issue=#${NUMBER} session=${SESSION} backend=${FIX_BACKEND}"
echo "started=$(date -u +%FT%TZ)"

# ---- clone + task brief -------------------------------------------
echo "==> cloning ${REPO}"
git clone --depth 50 \
    "https://x-access-token:${TOKEN}@github.com/${REPO}.git" \
    "${WORK}/repo" || { echo "clone failed"; exit 4; }

ISSUE_JSON=$(api GET "/repos/${REPO}/issues/${NUMBER}")
TASK_FILE="${WORK}/repo/TASK.md"
python3 - "$ISSUE_JSON" "$MODE" > "${TASK_FILE}" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); mode = sys.argv[2]
print(f"# Issue #{d.get('number')}: {d.get('title','')}\n")
print(d.get("body") or "(no description)")
print("\n---\n")
if mode == "fixit":
    print(
      "You are in a clone of this repo. Diagnose the failure and make the\n"
      "minimal correct fix. Iterate until the build + tests pass — no turn\n"
      "limit. When done, WRITE A FULL EXPLANATION of the root cause and your\n"
      "fix to `FIX_WRITEUP.md` in the repo root (markdown; this is posted to\n"
      "the GitHub issue verbatim). Leave changes in the working tree; do not\n"
      "push.")
else:
    print("Interactive session: the repo is checked out here with the full\n"
          "toolchain + claude available. Work freely.")
PY

# ---- build cycle detection ----------------------------------------
if [[ -z "${BUILD_CMD}" ]]; then
    if   [[ -f "${WORK}/repo/Cargo.toml" ]]; then BUILD_CMD="cargo build --all && cargo test --all --no-fail-fast"
    elif [[ -f "${WORK}/repo/go.mod"     ]]; then BUILD_CMD="go build ./... && go test ./..."
    elif [[ -f "${WORK}/repo/Makefile"   ]]; then BUILD_CMD="make"
    else BUILD_CMD="echo '(no build system detected)'"; fi
fi
echo "==> build: ${BUILD_CMD}"

# ====================================================================
# INTERACTIVE — set up + hand the shell to the user, then idle.
# ====================================================================
if [[ "${MODE}" == "interactive" ]]; then
    cat > "${WORK}/attach.txt" <<TXT
forcicd interactive session **${SESSION}** is live on forcicd.g8.lo.

Attach:  ssh fedora@forcicd.g8.lo  →  sudo screen -r ${SESSION}
Inside:  the repo is at /work with git, vi, claude + toolchain.
End it:  exit the shell (Ctrl-D), or 'sudo screen -X -S ${SESSION} quit'.
TXT
    comment "${WORK}/attach.txt"
    echo "==> launching interactive container; attach with: screen -r ${SESSION}"
    if [[ "${FIX_BACKEND}" == "docker" ]]; then
        exec sudo docker run --rm -it --name "${SESSION}" \
            --security-opt seccomp=unconfined --network forcicd_default \
            -v "${WORK}/repo:/work" -w /work ${FIX_MOUNTS} \
            "${FIX_IMAGE}" bash -l
    else
        exec "${0%/*}/fix-lxc.sh" interactive "${SESSION}" "${WORK}/repo"
    fi
    exit 0
fi

# ====================================================================
# FIXIT — autonomous Claude + build cycle, then writeup / close.
# ====================================================================
if [[ -z "${CLAUDE_CMD}" ]]; then
    echo "!! CLAUDE_CMD not set in ${ENVF}; running build-only (no fix)."
    INNER="cd /work && ${BUILD_CMD}"
else
    INNER="cd /work && ${CLAUDE_CMD} < /work/TASK.md ; echo '=== build cycle ===' ; ${BUILD_CMD}"
fi

echo "==> launching ${FIX_BACKEND} fix container ${SESSION}"
set +e
if [[ "${FIX_BACKEND}" == "docker" ]]; then
    sudo docker pull "${FIX_IMAGE}" >/dev/null 2>&1 || true
    timeout "${FIX_MAX_MINUTES}m" sudo docker run --rm --name "${SESSION}" \
        --security-opt seccomp=unconfined --network forcicd_default \
        -v "${WORK}/repo:/work" -w /work ${FIX_MOUNTS} \
        "${FIX_IMAGE}" bash -lc "${INNER}"
    RC=$?
else
    timeout "${FIX_MAX_MINUTES}m" "${0%/*}/fix-lxc.sh" fixit "${SESSION}" "${WORK}/repo" "${INNER}"
    RC=$?
fi
set -e
echo "==> fix container exited rc=${RC}"

# ---- assemble the writeup + result --------------------------------
RESULT_FILE="${WORK}/result.md"
{
    if [[ ${RC} -eq 0 ]]; then echo "### ✅ forcicd autonomous fix — build is green"
    else echo "### ⚠️ forcicd autonomous fix — build still failing (rc=${RC})"; fi
    echo
    if [[ -f "${WORK}/repo/FIX_WRITEUP.md" ]]; then
        cat "${WORK}/repo/FIX_WRITEUP.md"
    else
        echo "_(Claude produced no FIX_WRITEUP.md; showing the diff instead.)_"
    fi
    echo
    echo "<details><summary>diff</summary>"
    echo; echo '```diff'
    ( cd "${WORK}/repo" && git diff --stat && echo && git diff | head -400 )
    echo '```'; echo "</details>"
    echo
    echo "<details><summary>transcript tail</summary>"
    echo; echo '```'; tail -c 4000 "${LOG}"; echo '```'; echo "</details>"
    echo
    echo "_session \`${SESSION}\` · backend ${FIX_BACKEND} · env discarded._"
} > "${RESULT_FILE}"
comment "${RESULT_FILE}"

# ---- green build: push (optional) + close the issue ---------------
if [[ ${RC} -eq 0 ]]; then
    if [[ "${FIX_PUSH}" == "true" ]]; then
        BR="forcicd/fix-${NUMBER}"
        ( cd "${WORK}/repo"
          git config user.name forcicd; git config user.email ci@g8.lo
          git checkout -b "${BR}"
          git add -A && git commit -m "fix: resolve #${NUMBER} (forcicd autonomous)" || true
          git push "https://x-access-token:${TOKEN}@github.com/${REPO}.git" "${BR}" )
        api POST "/repos/${REPO}/pulls" \
            "{\"title\":\"forcicd fix for #${NUMBER}\",\"head\":\"forcicd/fix-${NUMBER}\",\"base\":\"main\",\"body\":\"Closes #${NUMBER}\"}" \
            >/dev/null 2>&1 || true
    fi
    echo "==> build green — closing issue #${NUMBER}"
    api PATCH "/repos/${REPO}/issues/${NUMBER}" '{"state":"closed","state_reason":"completed"}' \
        -o /dev/null -w "  close HTTP %{http_code}\n" 2>/dev/null \
      || curl -sS -X PATCH -H "Authorization: Bearer ${TOKEN}" \
            "https://api.github.com/repos/${REPO}/issues/${NUMBER}" \
            -d '{"state":"closed","state_reason":"completed"}' \
            -o /dev/null -w "  close HTTP %{http_code}\n"
fi

# ---- teardown -----------------------------------------------------
rm -rf "${WORK}"
echo "done=$(date -u +%FT%TZ) rc=${RC}"
