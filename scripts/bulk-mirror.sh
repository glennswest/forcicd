#!/usr/bin/env bash
# Mirror many GitHub repos into Forgejo at once, so their existing
# .github/workflows run on the local runner.
#
# Usage:
#   ./scripts/bulk-mirror.sh REPO [REPO ...]
#       mirror specific repos (owner/name or just name → defaults
#       to UPSTREAM_REPO_OWNER from proxmox.env)
#
#   ./scripts/bulk-mirror.sh --active [DAYS]
#       mirror every repo you own pushed within DAYS (default 30),
#       discovered via the GitHub token on the VM + `gh`-style API.
#
# Idempotent: repos already mirrored are skipped.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

PW_FILE="${REPO_ROOT}/build/admin-password"
[[ -f "${PW_FILE}" ]] || { echo "run bootstrap.sh first (no ${PW_FILE})" >&2; exit 2; }
PW=$(cat "${PW_FILE}")

mirror_one() {
    local full="$1"                       # owner/name
    local owner="${full%%/*}"
    local name="${full##*/}"
    # Already present?
    if curl -s -u "ci:${PW}" \
        "http://forcicd.g8.lo:3000/api/v1/repos/${FORGEJO_ADMIN_USER}/${name}" \
        | grep -q '"id"'; then
        echo "  = ${name} (already mirrored)"
        return
    fi
    curl -s -u "ci:${PW}" -X POST \
        "http://forcicd.g8.lo:3000/api/v1/repos/migrate" \
        -H 'Content-Type: application/json' \
        -d "{\"repo_name\":\"${name}\",\"clone_addr\":\"https://github.com/${owner}/${name}.git\",\"mirror\":true,\"mirror_interval\":\"1m0s\",\"repo_owner\":\"${FORGEJO_ADMIN_USER}\",\"service\":\"github\"}" \
        >/dev/null && echo "  + ${name} (mirrored)" \
        || echo "  ! ${name} (migrate failed)"
}

if [[ "${1:-}" == "--active" ]]; then
    DAYS="${2:-30}"
    echo "==> discovering repos pushed in the last ${DAYS}d"
    CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -d "${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)
    # Pull the list from GitHub via the token on the VM.
    REPOS=$(ssh "${VM_SSH}" "curl -s -H \"Authorization: Bearer \$(sudo cat /etc/forcicd/github-token)\" \
        'https://api.github.com/user/repos?per_page=100&affiliation=owner&sort=pushed&direction=desc'" \
        | python3 -c "
import json,sys,os
cutoff='${CUTOFF}'
for r in json.load(sys.stdin):
    if (r.get('pushed_at') or '') >= cutoff and not r.get('archived'):
        print(r['full_name'])")
    echo "==> mirroring $(echo "${REPOS}" | grep -c . ) repos"
    while IFS= read -r full; do
        [[ -n "${full}" ]] && mirror_one "${full}"
    done <<< "${REPOS}"
elif [[ $# -ge 1 ]]; then
    for arg in "$@"; do
        [[ "${arg}" == */* ]] || arg="${UPSTREAM_REPO_OWNER}/${arg}"
        mirror_one "${arg}"
    done
else
    echo "usage: $0 REPO [REPO ...]   |   $0 --active [DAYS]" >&2
    exit 2
fi

echo "done."
