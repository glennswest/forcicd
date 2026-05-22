#!/usr/bin/env bash
# Common helpers for forcicd scripts. Sourced via `source _lib.sh`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CONFIG="${REPO_ROOT}/proxmox.env"
if [[ ! -f "${CONFIG}" ]]; then
    echo "missing ${CONFIG} — copy from proxmox.env.sample first" >&2
    exit 2
fi
# shellcheck source=/dev/null
source "${CONFIG}"

VM_SSH="fedora@${VM_NAME}"

# ----- DNS (MicroDNS at 192.168.8.252) ---------------------------

dns_record_id() {
    local name="$1"
    curl --silent --max-time 5 \
        "${MICRODNS_URL}/zones/${G8_ZONE_ID}/records?limit=500" \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data:
    if r['name'] == '$name' and r['data'].get('type') == 'A':
        print(r['id'])
        break
"
}

ensure_a_record() {
    local name="$1"
    local ip="$2"
    local existing
    existing=$(dns_record_id "${name}")
    if [[ -n "${existing}" ]]; then
        curl --silent --max-time 5 -X PUT \
            "${MICRODNS_URL}/zones/${G8_ZONE_ID}/records/${existing}" \
            -H 'Content-Type: application/json' \
            -d "{\"data\":{\"type\":\"A\",\"data\":\"${ip}\"},\"ttl\":300}" \
            > /dev/null
        echo "DNS: ${name}.g8.lo -> ${ip} (updated)"
    else
        curl --silent --max-time 5 -X POST \
            "${MICRODNS_URL}/zones/${G8_ZONE_ID}/records" \
            -H 'Content-Type: application/json' \
            -d "{\"name\":\"${name}\",\"ttl\":300,\"data\":{\"type\":\"A\",\"data\":\"${ip}\"},\"enabled\":true}" \
            > /dev/null
        echo "DNS: ${name}.g8.lo -> ${ip} (created)"
    fi
}

delete_a_record() {
    local name="$1"
    local existing
    existing=$(dns_record_id "${name}")
    if [[ -n "${existing}" ]]; then
        curl --silent --max-time 5 -X DELETE \
            "${MICRODNS_URL}/zones/${G8_ZONE_ID}/records/${existing}" \
            > /dev/null
        echo "DNS: ${name}.g8.lo removed"
    fi
}

# ----- Proxmox VM lifecycle (over SSH to PVE_HOST) ---------------

vm_exists() {
    ssh "${PVE_HOST}" "qm status ${VMID} >/dev/null 2>&1"
}

destroy_vm() {
    if vm_exists; then
        echo "VM ${VMID}: stopping + destroying"
        ssh "${PVE_HOST}" "qm stop ${VMID} --skiplock 1 --timeout 30 2>/dev/null || true; sleep 2; qm destroy ${VMID} --purge --destroy-unreferenced-disks 1"
    fi
}

create_vm() {
    if vm_exists; then
        echo "VM ${VMID} already exists; refuse to recreate (use destroy_vm first)" >&2
        return 1
    fi
    scp -q \
        "${REPO_ROOT}/cloud-init/forcicd-user-data.yaml" \
        "${REPO_ROOT}/cloud-init/forcicd-network-config.yaml" \
        "${PVE_HOST}:${PVE_SNIPPETS}/"
    ssh "${PVE_HOST}" "set -e
        qm create ${VMID} --name ${VM_NAME} --memory ${VM_MEMORY_MB} --cores ${VM_CORES} --sockets 1 \
            --cpu host --machine q35 --bios ovmf --ostype l26 \
            --net0 virtio,bridge=${PVE_BRIDGE} --agent enabled=1 \
            --scsihw virtio-scsi-single --serial0 socket --vga serial0
        qm set ${VMID} --efidisk0 ${PVE_STORAGE}:0,efitype=4m,pre-enrolled-keys=0,size=4M
        qm importdisk ${VMID} ${PVE_IMG} ${PVE_STORAGE} --format raw
        qm set ${VMID} --scsi0 ${PVE_STORAGE}:vm-${VMID}-disk-1,discard=on,iothread=1,ssd=1
        qm resize ${VMID} scsi0 ${VM_DISK_GB}G
        qm set ${VMID} --ide2 ${PVE_STORAGE}:cloudinit
        qm set ${VMID} --cicustom \"user=local:snippets/forcicd-user-data.yaml,network=local:snippets/forcicd-network-config.yaml\"
        qm set ${VMID} --ipconfig0 ip=${VM_IP}/24,gw=192.168.8.1
        qm set ${VMID} --boot order=scsi0"
    echo "VM ${VMID} (${VM_NAME} @ ${VM_IP}) created"
}

start_vm() {
    ssh "${PVE_HOST}" "qm start ${VMID}"
    echo "VM ${VMID} started"
}

wait_for_ssh() {
    local deadline_secs="${1:-600}"
    local start=$(date +%s)
    while true; do
        if (( $(date +%s) - start > deadline_secs )); then
            echo "${VM_NAME}: SSH did not answer in ${deadline_secs}s" >&2
            return 1
        fi
        if ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "${VM_SSH}" 'echo ok' >/dev/null 2>&1; then
            echo "${VM_NAME}: SSH ready after $(($(date +%s) - start))s"
            return 0
        fi
        sleep 5
    done
}
