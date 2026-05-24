#!/usr/bin/env bash
# Make an existing Fedora LXC able to run podman pods/containers
# (forcicd#2, "run a pod inside a Fedora LXC"). Targets the LXC
# DIRECTLY over ssh — never the Proxmox host. The CT itself is
# created once, out of band, with:
#     pct ... --unprivileged 1 --features nesting=1,fuse=1,keyctl=1
# (that one-time host step is yours; forcicd never touches pve).
#
# This script, run against the booted CT, installs + configures the
# in-LXC bits so rootless podman works:
#   - podman, buildah, skopeo, fuse-overlayfs, catatonit, slirp4netns
#   - /etc/containers/storage.conf (overlay + fuse-overlayfs mount_program)
#   - subuid/subgid for the deploy user (rootless ranges)
#   - lingering so the user's podman survives logout (pods stay up)
#   - a sanity `podman run` + `podman play kube` probe
#
# Usage:
#   ./scripts/prepare-lxc-pod-host.sh <target-host> [user]
#   e.g. ./scripts/prepare-lxc-pod-host.sh qregistry.g8.lo root

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

TARGET_HOST="${1:?usage: prepare-lxc-pod-host.sh <target-host> [user]}"
TARGET_USER="${2:-root}"
TARGET="${TARGET_USER}@${TARGET_HOST}"

echo "==> configuring ${TARGET} to run podman pods"
ssh "${TARGET}" 'sudo bash -se' <<'REMOTE'
set -euo pipefail

echo "-- packages"
dnf install -y --setopt=install_weak_deps=False \
    podman buildah skopeo fuse-overlayfs catatonit slirp4netns shadow-utils \
    >/dev/null

echo "-- containers storage (nested overlay needs fuse-overlayfs)"
install -d -m 0755 /etc/containers
cat > /etc/containers/storage.conf <<'CONF'
[storage]
driver = "overlay"
[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
CONF
cat > /etc/containers/registries.conf <<'CONF'
unqualified-search-registries = ["docker.io"]
[[registry]]
location = "forcicd.g8.lo:5000"
insecure = true
[[registry]]
location = "fastregistry.g10.lo"
insecure = true
CONF

# Rootless ranges + lingering for the deploy user (so pods survive
# the ssh session ending). Default to root running rootful podman;
# if a non-root deploy user is used, give it subids + linger.
DEPLOY_USER="${SUDO_USER:-root}"
if [ "${DEPLOY_USER}" != "root" ]; then
    grep -q "^${DEPLOY_USER}:" /etc/subuid || usermod \
        --add-subuids 100000-165535 --add-subgids 100000-165535 "${DEPLOY_USER}"
    loginctl enable-linger "${DEPLOY_USER}" || true
fi

echo "-- probe: podman run"
podman run --rm forcicd.g8.lo:5000/forcicd-runner-ubuntu22:latest true 2>/dev/null \
    || podman run --rm registry.access.redhat.com/ubi9/ubi-minimal:latest true 2>/dev/null \
    || echo "  (probe image pull failed — registries reachable from the CT?)"

echo "-- probe: podman play kube"
cat > /tmp/_probe-pod.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: cigate-probe
spec:
  containers:
    - name: c
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["true"]
YAML
podman play kube --replace /tmp/_probe-pod.yaml >/dev/null 2>&1 && \
    podman play kube --down /tmp/_probe-pod.yaml >/dev/null 2>&1 && \
    echo "  podman play kube: OK" || echo "  podman play kube: needs attention"
rm -f /tmp/_probe-pod.yaml
echo "done."
REMOTE

cat <<EOF

${TARGET} is pod-ready.
  - Set APP_KIND/pod_manifest in /etc/forcicd-deploy/gate.conf and
    drop your pod spec at /etc/forcicd-deploy/pod.yaml.
  - cigate verbs 'pod up' / 'pod down' run it (podman play kube).
  - The CT must have been created with
    --features nesting=1,fuse=1,keyctl=1 (one-time, on pve, by you).
EOF
