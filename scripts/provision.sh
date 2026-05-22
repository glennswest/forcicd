#!/usr/bin/env bash
# Provision the forcicd VM: DNS record + Proxmox VM + wait for SSH.
# Idempotent — destroys an existing VM at the same VMID first.
#
# Usage: ./scripts/provision.sh [--force]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

FORCE=0
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

# Clear stale ssh-known-hosts entries so a recreated VM doesn't
# trip host-key warnings.
ssh-keygen -R "${VM_NAME}" >/dev/null 2>&1 || true
ssh-keygen -R "${VM_IP}"   >/dev/null 2>&1 || true

ensure_a_record forcicd "${VM_IP}"

if vm_exists && [[ ${FORCE} -ne 1 ]]; then
    echo "VM ${VMID} already exists; pass --force to recreate"
    if ssh -o ConnectTimeout=3 -o BatchMode=yes \
        "${VM_SSH}" 'echo ok' >/dev/null 2>&1; then
        echo "${VM_NAME}: already reachable. Skipping provisioning."
        exit 0
    fi
    echo "${VM_NAME}: VM exists but SSH not reachable; aborting." >&2
    exit 1
fi

destroy_vm
create_vm
start_vm
wait_for_ssh
echo "provision done"
