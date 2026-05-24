#!/usr/bin/env bash
# LXC backend for the auto-fix worker. Spins a throwaway CT on
# pve.g8.lo by cloning a prebuilt template (FIX_LXC_TEMPLATE) that
# has git + vi + claude + the toolchain baked in, runs the work
# inside it, and destroys it.
#
# Called by fix-worker.sh; not meant to be run directly.
#
#   fix-lxc.sh fixit       <session> <repo-path> <inner-cmd>
#   fix-lxc.sh interactive <session> <repo-path>
#
# <repo-path> is the host clone (used to learn the clone URL +,
# for fixit, to receive FIX_WRITEUP.md + the diff back so the
# worker's posting logic is backend-agnostic).

set -uo pipefail
ACTION="${1:?action}"; SESSION="${2:?session}"; REPO_PATH="${3:?repo path}"
INNER="${4:-}"

ENVF=/etc/forcicd/fix.env
[[ -f "${ENVF}" ]] && source "${ENVF}"
: "${PVE_HOST:=root@pve.g8.lo}"
: "${FIX_LXC_TEMPLATE:=}"          # template CT id to clone (required)
: "${FIX_LXC_STORAGE:=local-lvm}"
: "${FIX_LXC_IDBASE:=9000}"        # ephemeral CT ids start here

if [[ -z "${FIX_LXC_TEMPLATE}" ]]; then
    echo "FIX_LXC_TEMPLATE not set in ${ENVF} — build a template CT" >&2
    echo "(git+vi+claude+toolchain) and set its id. See fix.env.sample." >&2
    exit 5
fi

# Derive the github clone URL from the host clone's origin.
ORIGIN=$(git -C "${REPO_PATH}" remote get-url origin 2>/dev/null)
# Pick a free ephemeral CT id.
CTID=$(ssh "${PVE_HOST}" "for i in \$(seq ${FIX_LXC_IDBASE} $((FIX_LXC_IDBASE+200))); do pct status \$i >/dev/null 2>&1 || { echo \$i; break; }; done")
[[ -n "${CTID}" ]] || { echo "no free CT id" >&2; exit 6; }
echo "==> lxc: cloning template ${FIX_LXC_TEMPLATE} -> CT ${CTID} (${SESSION})"

cleanup() {
    ssh "${PVE_HOST}" "pct stop ${CTID} --skiplock 1 2>/dev/null; pct destroy ${CTID} --purge 2>/dev/null" || true
}
trap cleanup EXIT

ssh "${PVE_HOST}" "set -e
    pct clone ${FIX_LXC_TEMPLATE} ${CTID} --hostname ${SESSION} --storage ${FIX_LXC_STORAGE}
    pct start ${CTID}
    for i in \$(seq 1 30); do pct exec ${CTID} -- true 2>/dev/null && break; sleep 1; done
    pct exec ${CTID} -- git clone --depth 50 '${ORIGIN}' /work 2>&1 | tail -2"

if [[ "${ACTION}" == "interactive" ]]; then
    echo "==> lxc interactive: entering CT ${CTID} (Ctrl-D to end + destroy)"
    # Hand the user a shell inside the CT. When they exit, the trap
    # destroys the CT.
    ssh -t "${PVE_HOST}" "pct exec ${CTID} -- bash -lc 'cd /work; exec bash -l'"
    exit 0
fi

# fixit: run the inner command (claude + build) inside the CT.
echo "==> lxc fixit: running fix + build in CT ${CTID}"
# Rewrite /work path is already correct inside the CT.
ssh "${PVE_HOST}" "pct exec ${CTID} -- bash -lc '${INNER}'"
RC=$?

# Pull the writeup + diff back to the host clone so fix-worker's
# posting logic (which reads ${REPO_PATH}) works unchanged.
ssh "${PVE_HOST}" "pct exec ${CTID} -- bash -lc 'cat /work/FIX_WRITEUP.md 2>/dev/null'" \
    > "${REPO_PATH}/FIX_WRITEUP.md" 2>/dev/null || true
ssh "${PVE_HOST}" "pct exec ${CTID} -- bash -lc 'cd /work && git diff'" \
    > "${REPO_PATH}/.lxc.diff" 2>/dev/null || true
# Stage the diff into the host clone so `git diff` there shows it.
if [[ -s "${REPO_PATH}/.lxc.diff" ]]; then
    ( cd "${REPO_PATH}" && git apply --whitespace=nowarn "${REPO_PATH}/.lxc.diff" 2>/dev/null || true )
    rm -f "${REPO_PATH}/.lxc.diff"
fi
exit ${RC}
