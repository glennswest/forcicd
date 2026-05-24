#!/usr/bin/env bash
# Build the base LXC template the auto-fix LXC backend clones.
#
# Creates a CT on pve.g8.lo with git + vi + screen + build
# toolchains + Node.js (Claude Code needs node), converts it to a
# template, and prints the steps for YOU to install your Claude
# client + the history/indexing add-on into it (that's the part
# tied to your subscription).
#
# Usage:
#   ./scripts/build-fix-lxc-template.sh [CTID]
#       CTID defaults to 9000 (matches FIX_LXC_IDBASE-1 convention).
#
# Claude Code is large — the template gets a 32 GiB root by default
# (override with TEMPLATE_DISK_GB). After you bake claude in,
# `pct template <id>` it (this script does the base; re-run
# `pct template` yourself after installing claude if you cloned to
# customize).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

CTID="${1:-9000}"
: "${PVE_HOST:=root@pve.g8.lo}"
: "${TEMPLATE_DISK_GB:=32}"
: "${TEMPLATE_MEM_MB:=8192}"
: "${TEMPLATE_CORES:=4}"
: "${TEMPLATE_BRIDGE:=vmbr0}"
: "${TEMPLATE_OSTEMPLATE:=}"   # e.g. local:vztmpl/debian-12-standard_*.tar.zst

echo "==> finding an OS template on ${PVE_HOST}"
if [[ -z "${TEMPLATE_OSTEMPLATE}" ]]; then
    TEMPLATE_OSTEMPLATE=$(ssh "${PVE_HOST}" \
        "pveam list local 2>/dev/null | awk '/debian-12-standard/{print \$1}' | head -1")
fi
[[ -n "${TEMPLATE_OSTEMPLATE}" ]] || {
    echo "no debian-12-standard template on ${PVE_HOST}." >&2
    echo "Download one:  ssh ${PVE_HOST} 'pveam update && pveam available | grep debian-12-standard'" >&2
    echo "then           ssh ${PVE_HOST} 'pveam download local <name>'" >&2
    exit 2
}
echo "    using ${TEMPLATE_OSTEMPLATE}"

if ssh "${PVE_HOST}" "pct status ${CTID} >/dev/null 2>&1"; then
    echo "CT ${CTID} already exists; destroy it first or pass another id" >&2
    exit 3
fi

echo "==> creating CT ${CTID} (fix-template)"
ssh "${PVE_HOST}" "set -e
    pct create ${CTID} ${TEMPLATE_OSTEMPLATE} \
        --hostname fix-template \
        --cores ${TEMPLATE_CORES} --memory ${TEMPLATE_MEM_MB} \
        --rootfs local-lvm:${TEMPLATE_DISK_GB} \
        --net0 name=eth0,bridge=${TEMPLATE_BRIDGE},ip=dhcp \
        --features nesting=1 \
        --unprivileged 1 --onboot 0
    pct start ${CTID}
    for i in \$(seq 1 30); do pct exec ${CTID} -- true 2>/dev/null && break; sleep 1; done"

echo "==> installing base toolchain (git, vi, screen, node, build deps)"
ssh "${PVE_HOST}" "pct exec ${CTID} -- bash -lc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        git vim screen curl wget ca-certificates jq sudo \
        build-essential pkg-config libssl-dev \
        python3 python3-pip nodejs npm \
        unzip xz-utils
    # rust + go are handy for the common repos
    curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path || true
    echo done'"

cat <<EOF

base template CT ${CTID} is up on ${PVE_HOST}.

NEXT — install YOUR Claude client + indexing add-on into it
(this part is tied to your subscription, so it is not scripted):

  ssh ${PVE_HOST}
  pct enter ${CTID}
    # install Claude Code (npm or the official installer), e.g.:
    #   npm install -g @anthropic-ai/claude-code
    # install the history/indexing add-on you use
    # log in / drop your subscription credentials so headless runs work
    # verify:  claude --version
    exit

  # then convert it to a template so the worker can clone it:
  pct stop ${CTID}
  pct template ${CTID}

Finally set in /etc/forcicd/fix.env on ${VM_NAME}:
  FIX_BACKEND=lxc
  FIX_LXC_TEMPLATE=${CTID}
  CLAUDE_CMD='<however you invoke claude headlessly>'
EOF
