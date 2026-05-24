#!/usr/bin/env bash
# Build the base LXC template the auto-fix LXC backend clones.
#
# This env does NOT build anything — forcicd's CI does all builds.
# It only needs git + an editor + Node.js (for Claude Code) so
# Claude can clone, edit, and commit back. No rust/go/gcc here.
#
# Creates a CT on pve.g8.lo, installs that minimal set, and prints
# the steps for YOU to install your Claude client + the
# history/indexing add-on (the part tied to your subscription),
# then `pct template` it.
#
# Usage:
#   ./scripts/build-fix-lxc-template.sh [CTID]   # default 9000
#
# Claude Code itself is large — the template gets a 16 GiB root by
# default (override with TEMPLATE_DISK_GB). The codebase index is
# kept OUTSIDE the template (bind-mounted per repo) so it persists
# across throwaway clones and you don't re-spend tokens re-indexing.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

CTID="${1:-9000}"
: "${PVE_HOST:=root@pve.g8.lo}"
: "${TEMPLATE_DISK_GB:=16}"
: "${TEMPLATE_MEM_MB:=4096}"
: "${TEMPLATE_CORES:=2}"
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

echo "==> installing the minimal env (git, vim, screen, node — NO build toolchain)"
ssh "${PVE_HOST}" "pct exec ${CTID} -- bash -lc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        git vim screen curl wget ca-certificates jq sudo openssh-client \
        nodejs npm python3
    git config --system user.name forcicd
    git config --system user.email ci@g8.lo
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
