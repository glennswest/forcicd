#!/usr/bin/env bash
# Build the forcicd-runner image on the forcicd VM and push it to
# the local registry. The image carries the toolchains CI workflows
# expect: rust (+ aarch64 targets), go, C (+ aarch64 cross), kernel
# build prereqs, docker CLI + buildx, QEMU for multi-arch builds.
#
# Idempotent — rebuilding is safe; layers cache.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

IMAGE_TAG="${RUNNER_IMAGE_TAG:-${LOCAL_REGISTRY}/forcicd-runner:latest}"

echo "==> sync Dockerfile to ${VM_NAME}"
ssh "${VM_SSH}" 'install -d -m 0755 /tmp/runner-image'
scp -q "${REPO_ROOT}/runner-image/Dockerfile" "${VM_SSH}:/tmp/runner-image/Dockerfile"

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
    # Bring the forgejo + runner stack back up after the docker
    # restart (compose deps reconnect automatically).
    cd /etc/forcicd && docker compose up -d
fi
REMOTE

echo "==> build ${IMAGE_TAG}"
ssh "${VM_SSH}" "sudo docker build -t '${IMAGE_TAG}' /tmp/runner-image"

echo "==> push ${IMAGE_TAG}"
ssh "${VM_SSH}" "sudo docker push '${IMAGE_TAG}'"

echo "runner image built and pushed: ${IMAGE_TAG}"
