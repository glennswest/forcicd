#!/usr/bin/env bash
# Poll Forgejo for new successful workflow runs on the mirror's
# main branch. When the SHA advances past whatever's recorded in
# /var/lib/forcicd/last-deployed, fire deploy.sh.
#
# Designed to run from a systemd timer (every 30s). Idempotent —
# if last-deployed == latest-green, exits quietly.

set -uo pipefail

CONF=/etc/forcicd/deploy.env
[[ -f "${CONF}" ]] && source "${CONF}"
: "${FORGEJO_URL:=http://localhost:3000}"
: "${FORGEJO_REPO:=ci/fastetcd}"
: "${FORGEJO_BRANCH:=main}"
: "${FORGEJO_WORKFLOW:=ci.yml}"
: "${STATE_FILE:=/var/lib/forcicd/last-deployed}"
: "${DEPLOY_SCRIPT:=/opt/forcicd/deploy.sh}"
: "${ADMIN_PW_FILE:=/etc/forcicd/admin-password}"

install -d -m 0700 "$(dirname "${STATE_FILE}")"

if [[ ! -f "${ADMIN_PW_FILE}" ]]; then
    echo "no admin password at ${ADMIN_PW_FILE}; cannot poll Forgejo" >&2
    exit 2
fi

# Find latest workflow_run on the configured branch that
# concluded == success.
LATEST=$(curl --silent --max-time 5 --fail \
    -u "ci:$(cat "${ADMIN_PW_FILE}")" \
    "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/actions/runs?branch=${FORGEJO_BRANCH}&status=success&limit=1" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); rs=d.get("workflow_runs",[]); print(rs[0]["head_sha"] if rs else "")' \
    2>/dev/null)

if [[ -z "${LATEST}" ]]; then
    exit 0   # no green build yet
fi

LAST=""
[[ -f "${STATE_FILE}" ]] && LAST=$(cat "${STATE_FILE}")

if [[ "${LATEST}" == "${LAST}" ]]; then
    exit 0   # already deployed
fi

echo "$(date -u +%FT%TZ) deploying ${LATEST} (was ${LAST:-none})"
if "${DEPLOY_SCRIPT}" "${LATEST}"; then
    echo "${LATEST}" > "${STATE_FILE}"
    echo "$(date -u +%FT%TZ) deploy ok"
else
    echo "$(date -u +%FT%TZ) deploy FAILED for ${LATEST}; not advancing state" >&2
    exit 1
fi
