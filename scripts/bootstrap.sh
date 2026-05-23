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

# Helper: after the admin password lands locally, copy it to the
# VM so /etc/forcicd/admin-password (read-only-mounted into the
# dashboard + CD watcher) actually has a real password.
push_admin_password_to_vm() {
    if [[ -f "${PW_FILE}" ]]; then
        scp -q "${PW_FILE}" "${VM_SSH}:/tmp/admin-password"
        ssh "${VM_SSH}" 'sudo install -m 0600 /tmp/admin-password /etc/forcicd/admin-password && rm -f /tmp/admin-password'
    fi
}

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
# Always sync the password to the VM — install.sh created an
# empty placeholder, and the dashboard / CD watcher need the
# real value to authenticate against the Forgejo API.
push_admin_password_to_vm

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
# The runner container's entrypoint expects /data/.runner to exist
# and crash-loops without it. So we register via a one-shot
# `docker run` against the same named volume *before* the long-
# lived runner container can stay up. Detect either case: file
# already present, or container already happily running.
ALREADY=$(ssh "${VM_SSH}" "sudo docker volume inspect forcicd_runner-data -f '{{.Mountpoint}}'" 2>/dev/null | tr -d '\r\n')
if [[ -n "${ALREADY}" ]] && ssh "${VM_SSH}" "sudo test -f '${ALREADY}/.runner'"; then
    echo "    runner already registered"
else
    # Mint a global (system-scope) runner token.
    TOKEN=$(ssh "${VM_SSH}" "sudo docker exec -u 1000 forgejo forgejo forgejo-cli actions generate-runner-token" | tr -d '\r\n')
    if [[ -z "${TOKEN}" ]]; then
        echo "failed to generate runner token" >&2
        exit 3
    fi
    # Runner labels: every github-hosted `runs-on:` value the
    # fastetcd workflow uses is mapped to our local toolchain image
    # so cargo / go / cross-compile / kernel-build all just work.
    # RHEL labels cover the RHCOS lineage from OCP 4.7 → 5.0.
    # Alpine + Debian variants round out the major distro families.
    # `self-hosted:host` is the escape hatch for jobs that need to
    # touch the VM's docker / qemu directly.
    UB="${LOCAL_REGISTRY}/forcicd-runner-ubuntu22:latest"
    R8="${LOCAL_REGISTRY}/forcicd-runner-ubi8:latest"
    R9="${LOCAL_REGISTRY}/forcicd-runner-ubi9:latest"
    R10="${LOCAL_REGISTRY}/forcicd-runner-ubi10:latest"
    ALP="${LOCAL_REGISTRY}/forcicd-runner-alpine:latest"
    DEB12="${LOCAL_REGISTRY}/forcicd-runner-debian12:latest"
    DEB11="${LOCAL_REGISTRY}/forcicd-runner-debian11:latest"
    BOOTC="${LOCAL_REGISTRY}/forcicd-runner-bootc:latest"
    F43="${LOCAL_REGISTRY}/forcicd-runner-fedora43:latest"
    LABELS=(
        # Ubuntu (default for GitHub-hosted parity)
        "ubuntu-latest:docker://${UB}"
        "ubuntu-22.04:docker://${UB}"
        "ubuntu-24.04:docker://${UB}"
        # RHEL family
        "rhel-8:docker://${R8}"   "ubi-8:docker://${R8}"
        "rhel-9:docker://${R9}"   "ubi-9:docker://${R9}"
        "rhel-10:docker://${R10}" "ubi-10:docker://${R10}"
        # OCP-version aliases (OCP → RHCOS-base mapping)
        "ocp-4.7:docker://${R8}"   "ocp-4.8:docker://${R8}"
        "ocp-4.9:docker://${R8}"   "ocp-4.10:docker://${R8}"
        "ocp-4.11:docker://${R8}"  "ocp-4.12:docker://${R8}"
        "ocp-4.13:docker://${R9}"  "ocp-4.14:docker://${R9}"
        "ocp-4.15:docker://${R9}"  "ocp-4.16:docker://${R9}"
        "ocp-4.17:docker://${R9}"  "ocp-4.18:docker://${R9}"
        "ocp-4.19:docker://${R10}" "ocp-5.0:docker://${R10}"
        # Alpine (musl)
        "alpine:docker://${ALP}"      "alpine-latest:docker://${ALP}"
        # Debian
        "debian:docker://${DEB12}"    "debian-latest:docker://${DEB12}"
        "debian-12:docker://${DEB12}" "bookworm:docker://${DEB12}"
        "debian-11:docker://${DEB11}" "bullseye:docker://${DEB11}"
        # Bootc (bootable container) — for OCP-bootc / RHCOS-bootc work
        "bootc:docker://${BOOTC}"
        "bootc-c9s:docker://${BOOTC}"
        "bootc-centos9:docker://${BOOTC}"
        # Fedora (matches the forcicd VM's own OS)
        "fedora:docker://${F43}"
        "fedora-latest:docker://${F43}"
        "fedora-43:docker://${F43}"
        # Host escape hatch
        "self-hosted:host"
    )
    LABEL_CSV=$(IFS=,; echo "${LABELS[*]}")
    # Stop the crash-looping runner so we can write into its volume.
    ssh "${VM_SSH}" "sudo docker stop forgejo-runner >/dev/null 2>&1 || true"
    # One-shot register on the shared docker bridge so the runner
    # can resolve `forgejo:3000`.
    ssh "${VM_SSH}" "sudo docker run --rm \
        --network forcicd_default \
        -v forcicd_runner-data:/data \
        --user 0:0 \
        code.forgejo.org/forgejo/runner:6 \
        forgejo-runner register \
            --no-interactive \
            --instance http://forgejo:3000 \
            --token '${TOKEN}' \
            --name forcicd-runner \
            --labels '${LABEL_CSV}'" >/dev/null
    # Now start the long-lived runner.
    ssh "${VM_SSH}" "sudo docker start forgejo-runner" >/dev/null
    echo "    runner registered + started"
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
