#!/usr/bin/env bash
# Register the GitHub push token as a Forgejo Actions secret so
# workflows can push commits / cut releases back to GitHub via
# ${{ secrets.GH_PUSH_TOKEN }}.
#
# Usage:
#   ./scripts/set-gh-secret.sh                 # user-level (all ci/ repos)
#   ./scripts/set-gh-secret.sh <repo-name>     # just that mirrored repo
#   SECRET_NAME=FOO ./scripts/set-gh-secret.sh # custom secret name
#
# The token is read from /etc/forcicd/github-token on the VM (the
# bootstrap GitHub token, which has the `repo` scope).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

PW_FILE="${REPO_ROOT}/build/admin-password"
[[ -f "${PW_FILE}" ]] || { echo "run bootstrap.sh first (no ${PW_FILE})" >&2; exit 2; }
PW=$(cat "${PW_FILE}")
SECRET_NAME="${SECRET_NAME:-GH_PUSH_TOKEN}"

TOKEN=$(ssh "${VM_SSH}" 'sudo cat /etc/forcicd/github-token' | tr -d '\r\n')
[[ -n "${TOKEN}" ]] || { echo "no token at /etc/forcicd/github-token on the VM" >&2; exit 3; }

if [[ $# -ge 1 ]]; then
    REPO_NAME="$1"
    URL="http://forcicd.g8.lo:3000/api/v1/repos/${FORGEJO_ADMIN_USER}/${REPO_NAME}/actions/secrets/${SECRET_NAME}"
    SCOPE="repo ${FORGEJO_ADMIN_USER}/${REPO_NAME}"
else
    URL="http://forcicd.g8.lo:3000/api/v1/user/actions/secrets/${SECRET_NAME}"
    SCOPE="user ${FORGEJO_ADMIN_USER} (all repos)"
fi

CODE=$(curl -s -o /dev/null -w '%{http_code}' -u "ci:${PW}" -X PUT "${URL}" \
    -H 'Content-Type: application/json' \
    -d "{\"data\": \"${TOKEN}\"}")

case "${CODE}" in
    201|204) echo "secret ${SECRET_NAME} set for ${SCOPE}" ;;
    *) echo "failed to set secret (HTTP ${CODE})" >&2; exit 4 ;;
esac
