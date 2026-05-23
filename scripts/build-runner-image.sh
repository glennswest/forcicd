#!/usr/bin/env bash
# Build one (or all) of the forcicd-runner images on the forcicd VM
# and push to the local registry.
#
# Variants:
#   ubuntu22  - Ubuntu 22.04 (act-compatible default for ubuntu-* labels)
#   ubi8      - RHEL 8 (OCP 4.7 → 4.12)
#   ubi9      - RHEL 9 (OCP 4.13 → 4.18)
#   ubi10     - RHEL 10 (OCP 4.19+ / proposed 5.0)
#
# Usage:
#   ./scripts/build-runner-image.sh                # builds all
#   ./scripts/build-runner-image.sh ubuntu22       # one variant
#   ./scripts/build-runner-image.sh ubi8 ubi9      # several
#
# Optional env for RHEL subscription (passed as build args):
#   RHEL_ORG_ID=<org id>
#   RHEL_ACTIVATION_KEY=<activation key>
# When both are set, UBI builds register with subscription-manager
# and enable codeready-builder for full RHEL-equivalent packages.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

ALL_VARIANTS=(ubuntu22 ubi8 ubi9 ubi10 alpine debian12 debian11 bootc fedora43)
VARIANTS=("$@")
if [[ ${#VARIANTS[@]} -eq 0 ]]; then
    VARIANTS=("${ALL_VARIANTS[@]}")
fi

# Validate.
for v in "${VARIANTS[@]}"; do
    case "$v" in
        ubuntu22|ubi8|ubi9|ubi10|alpine|debian12|debian11|bootc|fedora43) ;;
        *) echo "unknown variant: $v (valid: ${ALL_VARIANTS[*]})" >&2; exit 2 ;;
    esac
done

BUILD_ARGS=""
if [[ -n "${RHEL_ORG_ID:-}" && -n "${RHEL_ACTIVATION_KEY:-}" ]]; then
    echo "==> using RHEL subscription (org=${RHEL_ORG_ID})"
    BUILD_ARGS="--build-arg RHEL_ORG_ID=${RHEL_ORG_ID} --build-arg RHEL_ACTIVATION_KEY=${RHEL_ACTIVATION_KEY}"
fi

echo "==> sync Dockerfiles to ${VM_NAME}"
ssh "${VM_SSH}" 'install -d -m 0755 /tmp/runner-image'
scp -q "${REPO_ROOT}/runner-image/"Dockerfile.* "${VM_SSH}:/tmp/runner-image/"

echo "==> configure docker daemon to allow http push to ${LOCAL_REGISTRY}"
ssh "${VM_SSH}" "sudo bash -se" <<REMOTE
set -euo pipefail
install -d -m 0755 /etc/docker
if [ ! -f /etc/docker/daemon.json ] \
   || ! grep -q '${LOCAL_REGISTRY}' /etc/docker/daemon.json; then
    cat >/etc/docker/daemon.json <<JSON
{
  "insecure-registries": ["${LOCAL_REGISTRY}"]
}
JSON
    systemctl restart docker
    cd /etc/forcicd && docker compose up -d
fi
REMOTE

for variant in "${VARIANTS[@]}"; do
    tag="${LOCAL_REGISTRY}/forcicd-runner-${variant}:latest"
    echo "==> docker build ${tag}"
    ssh "${VM_SSH}" "sudo docker build ${BUILD_ARGS} \
        -f /tmp/runner-image/Dockerfile.${variant} \
        -t '${tag}' \
        /tmp/runner-image"
    echo "==> docker push ${tag}"
    ssh "${VM_SSH}" "sudo docker push '${tag}'"
done

echo "done. built: ${VARIANTS[*]}"
