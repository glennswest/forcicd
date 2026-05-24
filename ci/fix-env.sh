#!/usr/bin/env bash
# Unified throwaway-environment runner for the auto-fix worker.
# Runs the prepared /work/run.sh inside either a throwaway LXC on
# pve.g8.lo (default) or a docker container on this VM, with the
# repo's cached Claude index mounted in for token savings.
#
# Called by fix-worker.sh; not meant to be run directly.
#   fix-env.sh <fixit|interactive> <session> <WORK> <IDX>
#
# WORK holds run.sh + TASK.md (host side); after a fixit run the
# repo's FIX_WRITEUP.md is left at <WORK>/writeup.md for the worker.

set -uo pipefail
ACTION="${1:?action}"; SESSION="${2:?session}"; WORK="${3:?work dir}"; IDX="${4:?index dir}"

ENVF=/etc/forcicd/fix.env
[[ -f "${ENVF}" ]] && source "${ENVF}"
: "${FIX_BACKEND:=lxc}"
: "${LOCAL_REGISTRY:=forcicd.g8.lo:5000}"
: "${FIX_IMAGE:=${LOCAL_REGISTRY}/forcicd-runner-ubuntu22:latest}"
: "${FIX_MOUNTS:=}"
# Where your Claude client keeps its codebase index/history inside
# the env. Mounted to the persistent per-repo IDX so re-runs reuse
# it instead of re-spending tokens to re-index.
: "${CLAUDE_INDEX_MOUNT:=/root/.claude}"
# lxc
: "${PVE_HOST:=root@pve.g8.lo}"
: "${FIX_LXC_TEMPLATE:=}"
: "${FIX_LXC_STORAGE:=local-lvm}"
: "${FIX_LXC_IDBASE:=9001}"
# pve-side persistent index root (bind-mounted into the CT; lives on
# the pve host since the CT runs there).
: "${PVE_INDEX_ROOT:=/var/lib/forcicd-claude-index}"

# ====================================================================
# DOCKER backend (runs on this VM)
# ====================================================================
if [[ "${FIX_BACKEND}" == "docker" ]]; then
    sudo docker pull "${FIX_IMAGE}" >/dev/null 2>&1 || true
    common=(--name "${SESSION}" --security-opt seccomp=unconfined
            --network forcicd_default
            -v "${WORK}:/work"
            -v "${IDX}:${CLAUDE_INDEX_MOUNT}"
            ${FIX_MOUNTS} -w /work)
    if [[ "${ACTION}" == "interactive" ]]; then
        exec sudo docker run --rm -it "${common[@]}" "${FIX_IMAGE}" bash -l
    fi
    sudo docker run --rm "${common[@]}" "${FIX_IMAGE}" bash -l /work/run.sh
    rc=$?
    # surface the writeup for the worker
    [[ -f "${WORK}/repo/FIX_WRITEUP.md" ]] && cp "${WORK}/repo/FIX_WRITEUP.md" "${WORK}/writeup.md"
    exit ${rc}
fi

# ====================================================================
# LXC backend (throwaway CT on pve.g8.lo)
# ====================================================================
if [[ -z "${FIX_LXC_TEMPLATE}" ]]; then
    echo "FIX_LXC_TEMPLATE not set — build one with scripts/build-fix-lxc-template.sh" >&2
    exit 5
fi

CTID=$(ssh "${PVE_HOST}" "for i in \$(seq ${FIX_LXC_IDBASE} $((FIX_LXC_IDBASE+200))); do pct status \$i >/dev/null 2>&1 || { echo \$i; break; }; done")
[[ -n "${CTID}" ]] || { echo "no free CT id on ${PVE_HOST}" >&2; exit 6; }
echo "==> lxc: clone template ${FIX_LXC_TEMPLATE} -> CT ${CTID} (${SESSION})"

cleanup() { ssh "${PVE_HOST}" "pct stop ${CTID} --skiplock 1 2>/dev/null; pct destroy ${CTID} --purge 2>/dev/null" || true; }
trap cleanup EXIT

# Persistent per-repo index dir on the pve host, bind-mounted in.
PVE_IDX="${PVE_INDEX_ROOT}/${SESSION%%-*}-$(basename "${IDX}")"
ssh "${PVE_HOST}" "set -e
    install -d -m 0755 '${PVE_IDX}'
    pct clone ${FIX_LXC_TEMPLATE} ${CTID} --hostname ${SESSION} --storage ${FIX_LXC_STORAGE}
    pct set ${CTID} -mp0 '${PVE_IDX},mp=${CLAUDE_INDEX_MOUNT}'
    pct start ${CTID}
    for i in \$(seq 1 30); do pct exec ${CTID} -- true 2>/dev/null && break; sleep 1; done
    pct exec ${CTID} -- install -d -m 0755 /work"

# Push run.sh + TASK.md into the CT.
ssh "${PVE_HOST}" "pct push ${CTID} - /work/run.sh --perms 0755" < "${WORK}/run.sh"
ssh "${PVE_HOST}" "pct push ${CTID} - /work/TASK.md" < "${WORK}/TASK.md"

if [[ "${ACTION}" == "interactive" ]]; then
    echo "==> entering CT ${CTID} (exit to end + destroy)"
    ssh -t "${PVE_HOST}" "pct exec ${CTID} -- bash -lc 'cd /work; exec bash -l'"
    exit 0
fi

echo "==> running fix in CT ${CTID}"
ssh "${PVE_HOST}" "pct exec ${CTID} -- bash -l /work/run.sh"
rc=$?
# Pull the writeup back for the worker, and surface the PUSHED/NOCHANGES
# marker into our stdout (which the worker greps from the log).
ssh "${PVE_HOST}" "pct exec ${CTID} -- bash -lc 'cat /work/repo/FIX_WRITEUP.md 2>/dev/null'" \
    > "${WORK}/writeup.md" 2>/dev/null || true
ssh "${PVE_HOST}" "pct exec ${CTID} -- bash -lc 'cd /work/repo && git rev-parse --abbrev-ref HEAD 2>/dev/null | grep -q forcicd/ && echo PUSHED ${SESSION}'" 2>/dev/null || true
exit ${rc}
