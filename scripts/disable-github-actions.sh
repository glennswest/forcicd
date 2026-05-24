#!/usr/bin/env bash
# Disable GitHub Actions on repos so CI only runs locally on
# forcicd. The workflow files stay in the repo (forcicd's mirror
# still runs them on the local runner) — this just stops
# github.com from executing them.
#
# Usage:
#   ./scripts/disable-github-actions.sh REPO [REPO ...]   # owner/name or name
#   ./scripts/disable-github-actions.sh --mirrored        # every repo
#       currently mirrored into Forgejo (ci/*)
#   ./scripts/disable-github-actions.sh --enable REPO ... # re-enable
#
# Reversible: `--enable` flips it back to enabled.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

ENABLED=false
ARGS=()
for a in "$@"; do
    case "$a" in
        --enable) ENABLED=true ;;
        *) ARGS+=("$a") ;;
    esac
done

TOKEN=$(ssh "${VM_SSH}" 'sudo cat /etc/forcicd/github-token' | tr -d '\r\n')
[[ -n "${TOKEN}" ]] || { echo "no token at /etc/forcicd/github-token" >&2; exit 3; }

set_actions() {
    local full="$1"
    [[ "${full}" == */* ]] || full="${UPSTREAM_REPO_OWNER}/${full}"
    local code
    code=$(curl -sS -X PUT \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${full}/actions/permissions" \
        -d "{\"enabled\":${ENABLED}}" \
        -o /dev/null -w '%{http_code}')
    if [[ "${code}" == "204" ]]; then
        echo "  $([[ ${ENABLED} == true ]] && echo enabled || echo disabled) ${full}"
    else
        echo "  ! ${full} (HTTP ${code})"
    fi
}

# Build the repo list.
REPO_LIST=""
if [[ "${ARGS[0]:-}" == "--mirrored" ]]; then
    PW=$(cat "${REPO_ROOT}/build/admin-password")
    # Enumerate Forgejo repos under the ci user, map to github owner.
    REPO_LIST=$(curl -s -u "ci:${PW}" \
        "http://forcicd.g8.lo:3000/api/v1/repos/search?uid=0&limit=200" \
        | python3 -c "
import json,sys,os
owner=os.environ['UPSTREAM_REPO_OWNER']
for r in json.load(sys.stdin).get('data',[]):
    print(f\"{owner}/{r['name']}\")")
else
    REPO_LIST=$(printf '%s\n' "${ARGS[@]}")
fi

[[ -n "${REPO_LIST}" ]] || { echo "no repos given (try --mirrored)" >&2; exit 2; }

COUNT=$(printf '%s\n' "${REPO_LIST}" | grep -c .)
echo "==> setting Actions enabled=${ENABLED} on ${COUNT} repos"
while IFS= read -r r; do
    [[ -n "${r}" ]] && set_actions "${r}"
done <<< "${REPO_LIST}"
echo "done."
