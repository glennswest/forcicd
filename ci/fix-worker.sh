#!/usr/bin/env bash
# forcicd auto-fix worker — one issue-driven session.
#
# The fix environment is deliberately MINIMAL: git + an editor +
# your Claude client. It does NOT build anything — forcicd's CI
# does all builds. The flow is:
#
#     clone the repo  →  Claude edits it  →  commit + push a branch
#     →  open a PR  →  forcicd CI builds the PR (separate)
#
# Modes:
#   fixit       autonomous. Claude fixes with no turn limit, writes
#               FIX_WRITEUP.md, commits + pushes forcicd/fix-<n>,
#               opens a PR; the writeup is posted to the issue.
#               forcicd CI then validates the PR; close-on-green is
#               handled by the CI side, not here.
#   interactive spin the env with repo + Claude ready, leave an
#               attachable screen session. You drive + commit.
#
# Backend (FIX_BACKEND): `lxc` (default — throwaway CT on pve.g8.lo
# cloned from a prebuilt template) or `docker` (container on this
# VM). The Claude codebase index is cached per-repo on persistent
# storage and mounted in, so re-runs don't re-spend tokens.
#
# Runs in a screen session <session> (sudo screen -r <session>).
# Config: /etc/forcicd/fix.env.  Args: <owner/repo> <issue#> <session> <mode>

set -uo pipefail

REPO="${1:?usage: fix-worker.sh <owner/repo> <issue#> <session> <mode>}"
NUMBER="${2:?missing issue number}"
SESSION="${3:?missing session name}"
MODE="${4:-fixit}"

ENVF=/etc/forcicd/fix.env
[[ -f "${ENVF}" ]] && source "${ENVF}"
: "${GH_TOKEN_FILE:=/etc/forcicd/github-token}"
: "${WORKROOT:=/var/lib/forcicd/fix-workspaces}"
: "${LOGROOT:=/var/lib/forcicd/fix-logs}"
: "${CLAUDE_INDEX_ROOT:=/var/lib/forcicd/claude-index}"  # persistent, per-repo
: "${FIX_BACKEND:=lxc}"
: "${CLAUDE_CMD:=}"                # THE HOOK — your claude client
: "${FIX_BASE_BRANCH:=main}"
: "${FIX_MAX_MINUTES:=120}"

TOKEN=$(cat "${GH_TOKEN_FILE}" 2>/dev/null || true)
[[ -n "${TOKEN}" ]] || { echo "no github token at ${GH_TOKEN_FILE}" >&2; exit 3; }

NAME="${REPO##*/}"
BRANCH="forcicd/fix-${NUMBER}"
WORK="${WORKROOT}/${SESSION}"
LOG="${LOGROOT}/${SESSION}.log"
IDX="${CLAUDE_INDEX_ROOT}/${NAME}"          # cached Claude index for this repo
install -d -m 0755 "${WORKROOT}" "${LOGROOT}" "${IDX}"
rm -rf "${WORK}"; install -d -m 0755 "${WORK}"
exec > >(tee -a "${LOG}") 2>&1

api() {  # api METHOD PATH [JSON]
    local m="$1" p="$2" d="${3:-}"
    local -a a=(-sS -X "${m}" -H "Authorization: Bearer ${TOKEN}"
                -H "Accept: application/vnd.github+json")
    [[ -n "${d}" ]] && a+=(-d "${d}")
    curl "${a[@]}" "https://api.github.com${p}"
}
comment() {  # comment <body-file>
    local body; body=$(python3 -c 'import json,sys; print(json.dumps({"body": open(sys.argv[1]).read()}))' "$1")
    api POST "/repos/${REPO}/issues/${NUMBER}/comments" "${body}" >/dev/null \
        && echo "  commented on #${NUMBER}"
}

echo "=== forcicd ${MODE} worker ==="
echo "repo=${REPO} issue=#${NUMBER} session=${SESSION} backend=${FIX_BACKEND} branch=${BRANCH}"
echo "started=$(date -u +%FT%TZ)"

# ---- task brief (fetched host-side, injected into the env) --------
ISSUE_JSON=$(api GET "/repos/${REPO}/issues/${NUMBER}")
python3 - "$ISSUE_JSON" "$MODE" > "${WORK}/TASK.md" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); mode = sys.argv[2]
print(f"# Issue #{d.get('number')}: {d.get('title','')}\n")
print(d.get("body") or "(no description)")
print("\n---\n")
if mode == "fixit":
    print("You are in a fresh clone of this repo (cwd). Diagnose and make the\n"
          "minimal correct fix. You have git + an editor + your tools, but NO\n"
          "build toolchain — do NOT try to compile; forcicd's CI builds and\n"
          "validates your change after you push. When done, write a full\n"
          "root-cause + fix explanation to FIX_WRITEUP.md in the repo root\n"
          "(markdown — posted to the GitHub issue verbatim), then stop. The\n"
          "worker commits + pushes your tree to a branch and opens a PR.")
else:
    print("Interactive session: the repo is checked out here with git + editor\n"
          "+ claude. Edit + commit + push as you like.")
PY

# The in-env script: clone (token URL) → run claude on the brief →
# (fixit) commit + push the branch. Identical for both backends.
RUNNER="${WORK}/run.sh"
cat > "${RUNNER}" <<EOF
#!/usr/bin/env bash
set -uo pipefail
cd /work
echo "==> cloning ${REPO}"
git clone --depth 50 "https://x-access-token:${TOKEN}@github.com/${REPO}.git" repo || exit 4
cd repo
cp /work/TASK.md ./TASK.md
EOF
if [[ "${MODE}" == "fixit" ]]; then
    if [[ -z "${CLAUDE_CMD}" ]]; then
        cat >> "${RUNNER}" <<'EOF'
echo "!! CLAUDE_CMD not set — no fix attempt. Edit /etc/forcicd/fix.env."
EOF
    else
        cat >> "${RUNNER}" <<EOF
echo "==> running claude (no turn limit)"
${CLAUDE_CMD} < ./TASK.md
echo "==> committing + pushing ${BRANCH}"
rm -f ./TASK.md
git checkout -b "${BRANCH}"
git add -A
if git commit -m "fix: autonomous fix for #${NUMBER} (forcicd+claude)"; then
    git push -f origin "${BRANCH}"
    echo "PUSHED ${BRANCH}"
else
    echo "NOCHANGES"
fi
EOF
    fi
fi
chmod +x "${RUNNER}"

# ====================================================================
# INTERACTIVE
# ====================================================================
if [[ "${MODE}" == "interactive" ]]; then
    cat > "${WORK}/attach.txt" <<TXT
forcicd interactive session **${SESSION}** is live on forcicd.g8.lo.

Attach:  ssh fedora@forcicd.g8.lo  →  sudo screen -r ${SESSION}
Inside:  /work/repo is the clone (git + editor + claude). Commit +
         push when ready; forcicd CI builds what you push.
End it:  exit the shell, or 'sudo screen -X -S ${SESSION} quit'.
TXT
    comment "${WORK}/attach.txt"
    echo "==> launching interactive ${FIX_BACKEND} env; attach: screen -r ${SESSION}"
    exec "${0%/*}/fix-env.sh" interactive "${SESSION}" "${WORK}" "${IDX}"
fi

# ====================================================================
# FIXIT — run the env, then open a PR + post the writeup.
# ====================================================================
echo "==> launching ${FIX_BACKEND} fix env ${SESSION}"
set +e
timeout "${FIX_MAX_MINUTES}m" "${0%/*}/fix-env.sh" fixit "${SESSION}" "${WORK}" "${IDX}"
RC=$?
set -e
echo "==> env exited rc=${RC}"

PUSHED=false
grep -q "^PUSHED " "${LOG}" && PUSHED=true

# Open a PR if we pushed a branch.
PR_URL=""
if ${PUSHED}; then
    PR_JSON=$(api POST "/repos/${REPO}/pulls" \
        "{\"title\":\"forcicd auto-fix for #${NUMBER}\",\"head\":\"${BRANCH}\",\"base\":\"${FIX_BASE_BRANCH}\",\"body\":\"Autonomous fix for #${NUMBER}. forcicd CI will validate. Closes #${NUMBER} when merged.\"}")
    PR_URL=$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("html_url",""))' <<<"${PR_JSON}" 2>/dev/null)
    echo "  PR: ${PR_URL:-（exists or failed）}"
fi

# Post the writeup to the issue.
RESULT="${WORK}/result.md"
{
    echo "### forcicd autonomous fix attempt — \`${SESSION}\`"
    echo
    if [[ -f "${WORK}/writeup.md" ]]; then cat "${WORK}/writeup.md"
    else echo "_(no FIX_WRITEUP.md produced)_"; fi
    echo
    if ${PUSHED}; then
        echo "Pushed branch \`${BRANCH}\`${PR_URL:+ — PR: ${PR_URL}}."
        echo "**forcicd CI is building it now;** the issue closes when that PR goes green."
    else
        echo "_No changes were committed._"
    fi
    echo
    echo "<details><summary>transcript tail</summary>"
    echo; echo '```'; tail -c 4000 "${LOG}"; echo '```'; echo "</details>"
    echo; echo "_env: ${FIX_BACKEND} · index cached at ${IDX} · session ${SESSION}_"
} > "${RESULT}"
comment "${RESULT}"

rm -rf "${WORK}"
echo "done=$(date -u +%FT%TZ) rc=${RC} pushed=${PUSHED}"
