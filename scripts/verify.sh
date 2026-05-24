#!/usr/bin/env bash
# End-to-end smoke check: hits every component of forcicd and
# returns nonzero on the first failure. Intended for CI of forcicd
# itself, or for manual confirmation after `make up`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

FAIL=0
ck() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  \033[32m✓\033[0m %s\n' "${desc}"
    else
        printf '  \033[31m✗\033[0m %s\n' "${desc}"
        FAIL=$((FAIL+1))
    fi
}

echo "==> infra"
ck "DNS resolves ${VM_NAME}"          bash -c "getent ahosts '${VM_NAME}' 2>/dev/null || host '${VM_NAME}' 2>/dev/null || dscacheutil -q host -a name '${VM_NAME}' 2>/dev/null | grep -q ip_address"
ck "VM ${VMID} exists on PVE"         vm_exists
ck "SSH reachable on the VM"          ssh -o ConnectTimeout=3 -o BatchMode=yes "${VM_SSH}" 'echo ok'
ck "Docker daemon running on the VM"  ssh "${VM_SSH}" 'sudo docker info >/dev/null 2>&1'

echo "==> forgejo"
ck "Forgejo API answers /version"     curl --silent --max-time 3 -fsS http://forcicd.g8.lo:3000/api/v1/version
ck "forgejo container is healthy"     ssh "${VM_SSH}" 'sudo docker inspect -f "{{.State.Running}}" forgejo | grep -q true'
ck "runner container is healthy"      ssh "${VM_SSH}" 'sudo docker inspect -f "{{.State.Running}}" forgejo-runner | grep -q true'
ck "runner is polling for jobs"       ssh "${VM_SSH}" 'sudo docker logs --tail 100 forgejo-runner 2>&1 | grep -q "\[poller 0\] launched"'

PW_FILE="${REPO_ROOT}/build/admin-password"
if [[ -f "${PW_FILE}" ]]; then
    PW=$(cat "${PW_FILE}")
    echo "==> mirror"
    REPO_URL="http://forcicd.g8.lo:3000/api/v1/repos/${FORGEJO_ADMIN_USER}/${UPSTREAM_REPO_NAME}"
    ck "mirror repo present"          curl --silent --max-time 5 -fsS -u "${FORGEJO_ADMIN_USER}:${PW}" "${REPO_URL}"
    ck "mirror branches API works"    curl --silent --max-time 5 -fsS -u "${FORGEJO_ADMIN_USER}:${PW}" "${REPO_URL}/branches"
else
    echo "==> skipping mirror checks (no admin password at ${PW_FILE})"
fi

echo "==> registry"
ck "${LOCAL_REGISTRY}/v2/ reachable"  curl --silent --max-time 3 -fsS "http://${LOCAL_REGISTRY}/v2/"

echo
if [[ ${FAIL} -eq 0 ]]; then
    echo "all checks passed."
    exit 0
else
    echo "${FAIL} check(s) failed."
    exit 1
fi
