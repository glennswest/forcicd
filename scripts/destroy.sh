#!/usr/bin/env bash
# Clean teardown — destroy the VM + remove the DNS record.
# Safe to call when the VM doesn't exist.
#
# Usage: ./scripts/destroy.sh [--keep-dns]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

KEEP_DNS=0
for a in "$@"; do
    case "$a" in
        --keep-dns) KEEP_DNS=1 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

destroy_vm
ssh-keygen -R "${VM_NAME}" >/dev/null 2>&1 || true
ssh-keygen -R "${VM_IP}"   >/dev/null 2>&1 || true
[[ ${KEEP_DNS} -eq 1 ]] || delete_a_record forcicd
echo "teardown complete"
