#!/usr/bin/env bash
# Print the current state of the forcicd system. Useful as a
# quick "is it healthy?" check or as the first thing to read
# after a reconnect.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '\033[32m%s\033[0m %s\n' '✓' "$*"; }
bad()   { printf '\033[31m%s\033[0m %s\n' '✗' "$*"; }
warn()  { printf '\033[33m%s\033[0m %s\n' '!' "$*"; }

bold "VM ${VMID} (${VM_NAME} @ ${VM_IP})"
if vm_exists; then
    STATE=$(ssh "${PVE_HOST}" "qm status ${VMID}" 2>/dev/null | awk '{print $2}')
    [[ "${STATE}" == "running" ]] && ok "qm status: ${STATE}" || bad "qm status: ${STATE}"
else
    bad "VM ${VMID} not present on ${PVE_HOST}"
    exit 1
fi

if ssh -o ConnectTimeout=3 -o BatchMode=yes "${VM_SSH}" 'echo ok' >/dev/null 2>&1; then
    ok "SSH reachable: ${VM_SSH}"
else
    bad "SSH unreachable: ${VM_SSH}"
    exit 1
fi

bold "Containers"
ssh "${VM_SSH}" 'sudo docker ps --format "{{.Names}}\t{{.Status}}\t{{.Image}}"' 2>/dev/null \
    | awk -F'\t' '{ printf "  %-18s %-30s %s\n", $1, $2, $3 }'

bold "Forgejo"
VER=$(curl --silent --max-time 3 http://forcicd.g8.lo:3000/api/v1/version 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo "")
if [[ -n "${VER}" ]]; then
    ok "API: ${VER}"
else
    bad "API not responding at http://forcicd.g8.lo:3000"
fi

bold "Mirror: ${UPSTREAM_REPO_OWNER}/${UPSTREAM_REPO_NAME}"
PW_FILE="${REPO_ROOT}/build/admin-password"
if [[ -f "${PW_FILE}" ]]; then
    PW=$(cat "${PW_FILE}")
    REPO=$(curl --silent --max-time 5 -u "${FORGEJO_ADMIN_USER}:${PW}" \
        "http://forcicd.g8.lo:3000/api/v1/repos/${FORGEJO_ADMIN_USER}/${UPSTREAM_REPO_NAME}" 2>/dev/null)
    if echo "${REPO}" | grep -q '"id"'; then
        BRANCH=$(echo "${REPO}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("default_branch","?"))')
        SIZE=$(echo "${REPO}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("size","?"))')
        UPDATED=$(echo "${REPO}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("updated_at","?"))')
        ok "mirror: branch=${BRANCH} size=${SIZE}KB updated=${UPDATED}"
    else
        bad "mirror repo not present or API auth failed"
    fi
else
    warn "admin-password not present at ${PW_FILE} — run bootstrap.sh"
fi

bold "Runner"
RUNNER_LOG=$(ssh "${VM_SSH}" 'sudo docker logs --tail 30 forgejo-runner 2>&1' 2>/dev/null)
if echo "${RUNNER_LOG}" | grep -q "Starting runner daemon"; then
    LABELS=$(echo "${RUNNER_LOG}" | grep -o 'with labels: \[[^]]*\]' | tail -1)
    ok "daemon up. ${LABELS}"
else
    bad "runner daemon not happy:"
    echo "${RUNNER_LOG}" | tail -5 | sed 's/^/    /'
fi

bold "Registry (push target): ${LOCAL_REGISTRY}"
if curl --silent --max-time 3 "http://${LOCAL_REGISTRY}/v2/" -o /dev/null -w '%{http_code}\n' \
   | grep -q '200'; then
    ok "${LOCAL_REGISTRY}/v2/ reachable"
    CAT=$(curl --silent --max-time 5 "http://${LOCAL_REGISTRY}/v2/_catalog" 2>/dev/null \
          | python3 -c 'import sys,json; d=json.load(sys.stdin); print(", ".join(r for r in d.get("repositories",[]) if "forcicd" in r) or "(no forcicd images yet)")' 2>/dev/null)
    echo "  forcicd images: ${CAT}"
else
    bad "${LOCAL_REGISTRY}/v2/ unreachable"
fi
