#!/usr/bin/env bash
# Idempotent bootstrap:
#   1. create admin user (password generated; saved locally to
#      build/admin-password, gitignored)
#   2. generate a runner registration token
#   3. register the act_runner against the local forgejo
#   4. create a mirrored repo for the upstream fastetcd repo
#
# Re-running is safe: each step detects existing state and skips.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

mkdir -p "${REPO_ROOT}/build"
PW_FILE="${REPO_ROOT}/build/admin-password"

# ----- 1. admin user --------------------------------------------
echo "==> ensure admin user '${FORGEJO_ADMIN_USER}'"
if ssh "${VM_SSH}" "sudo docker exec -u 1000 forgejo forgejo admin user list --admin 2>/dev/null | grep -qw '${FORGEJO_ADMIN_USER}'"; then
    echo "    admin already exists"
else
    if [[ ! -f "${PW_FILE}" ]]; then
        head -c 24 /dev/urandom | base64 | tr -d '/+=\n' | head -c 24 > "${PW_FILE}"
        chmod 600 "${PW_FILE}"
    fi
    PW=$(cat "${PW_FILE}")
    ssh "${VM_SSH}" "sudo docker exec -u 1000 forgejo forgejo admin user create \
        --admin --username '${FORGEJO_ADMIN_USER}' \
        --password '${PW}' --email '${FORGEJO_ADMIN_EMAIL}' \
        --must-change-password=false" >/dev/null
    echo "    admin created. Password at ${PW_FILE}"
fi

# Helper for authenticated API calls.
api() {
    local method="$1"; shift
    local path="$1"; shift
    local data="${1:-}"
    if [[ -n "${data}" ]]; then
        curl --silent --max-time 10 -u "${FORGEJO_ADMIN_USER}:$(cat "${PW_FILE}")" \
            -H 'Content-Type: application/json' \
            -X "${method}" "http://forcicd.g8.lo:3000${path}" -d "${data}"
    else
        curl --silent --max-time 10 -u "${FORGEJO_ADMIN_USER}:$(cat "${PW_FILE}")" \
            -X "${method}" "http://forcicd.g8.lo:3000${path}"
    fi
}

# ----- 2 + 3. runner registration token + register --------------
echo "==> ensure act_runner registered"
# If the runner already has /data/.runner, it's registered.
if ssh "${VM_SSH}" "sudo docker exec forgejo-runner test -f /data/.runner" 2>/dev/null; then
    echo "    runner already registered"
else
    # Mint a global (system-scope) runner token.
    TOKEN=$(ssh "${VM_SSH}" "sudo docker exec -u 1000 forgejo forgejo forgejo-cli actions generate-runner-token" | tr -d '\r\n')
    if [[ -z "${TOKEN}" ]]; then
        echo "failed to generate runner token" >&2
        exit 3
    fi
    ssh "${VM_SSH}" "sudo docker exec forgejo-runner forgejo-runner register \
        --no-interactive \
        --instance http://forgejo:3000 \
        --token '${TOKEN}' \
        --name forcicd-runner \
        --labels 'ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-22.04,ubuntu-22.04:docker://ghcr.io/catthehacker/ubuntu:act-22.04,self-hosted:host'" >/dev/null
    # Restart runner to pick up the registration.
    ssh "${VM_SSH}" "sudo docker restart forgejo-runner" >/dev/null
    echo "    runner registered + restarted"
fi

# ----- 4. mirror repo --------------------------------------------
echo "==> ensure mirror of ${UPSTREAM_REPO_URL}"
EXISTS=$(api GET "/api/v1/repos/${FORGEJO_ADMIN_USER}/${UPSTREAM_REPO_NAME}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("id",""))' 2>/dev/null || echo "")
if [[ -n "${EXISTS}" ]]; then
    echo "    mirror repo already exists (id=${EXISTS})"
else
    api POST "/api/v1/repos/migrate" \
        "{\"repo_name\":\"${UPSTREAM_REPO_NAME}\",\"clone_addr\":\"${UPSTREAM_REPO_URL}\",\"mirror\":true,\"mirror_interval\":\"1m0s\",\"repo_owner\":\"${FORGEJO_ADMIN_USER}\",\"service\":\"github\"}" \
        | python3 -m json.tool >/dev/null
    echo "    mirror repo created"
fi

cat <<EOF

bootstrap done.
   URL:    http://forcicd.g8.lo:3000/${FORGEJO_ADMIN_USER}/${UPSTREAM_REPO_NAME}
   Admin:  ${FORGEJO_ADMIN_USER}   pw in ${PW_FILE}
   Mirror: every 1m from ${UPSTREAM_REPO_URL}
   Runner: registered to /data/.runner; check
            sudo docker logs forgejo-runner
EOF
