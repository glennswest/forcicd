#!/usr/bin/env bash
# Install the CD half (deploy.sh + watcher.sh + systemd timer) on
# forcicd.g8.lo. Run after `make up` and `make images`. Idempotent.
#
# Optional: drop /etc/forcicd/kubetest.kubeconfig on the VM to
# enable the kubectl rollout step. Without it, the watcher still
# builds + pushes the image; only the cluster roll is skipped.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

PW_FILE="${REPO_ROOT}/build/admin-password"
if [[ ! -f "${PW_FILE}" ]]; then
    echo "missing ${PW_FILE} — run bootstrap.sh first" >&2
    exit 2
fi

echo "==> copy CD scripts + unit files to ${VM_NAME}"
scp -q "${REPO_ROOT}/cd/deploy.sh" "${REPO_ROOT}/cd/watcher.sh" \
    "${REPO_ROOT}/cd/forcicd-cd.service" "${REPO_ROOT}/cd/forcicd-cd.timer" \
    "${PW_FILE}" \
    "${VM_SSH}:/tmp/"

ssh "${VM_SSH}" 'sudo bash -se' <<REMOTE
set -euo pipefail
install -d -m 0755 /opt/forcicd /etc/forcicd /var/lib/forcicd
install -m 0755 /tmp/deploy.sh /opt/forcicd/deploy.sh
install -m 0755 /tmp/watcher.sh /opt/forcicd/watcher.sh
install -m 0600 /tmp/admin-password /etc/forcicd/admin-password
install -m 0644 /tmp/forcicd-cd.service /etc/systemd/system/forcicd-cd.service
install -m 0644 /tmp/forcicd-cd.timer   /etc/systemd/system/forcicd-cd.timer
rm -f /tmp/deploy.sh /tmp/watcher.sh /tmp/admin-password \
      /tmp/forcicd-cd.service /tmp/forcicd-cd.timer

# Default deploy.env (overridable on the VM).
[ -f /etc/forcicd/deploy.env ] || cat >/etc/forcicd/deploy.env <<ENVF
LOCAL_REGISTRY=${LOCAL_REGISTRY:-fastregistry.g10.lo}
FORGEJO_URL=http://localhost:3000
FORGEJO_REPO=${FORGEJO_ADMIN_USER:-ci}/${UPSTREAM_REPO_NAME:-fastetcd}
FORGEJO_BRANCH=main
IMAGE_NAME=fastetcd
ENVF
chmod 0644 /etc/forcicd/deploy.env

systemctl daemon-reload
systemctl enable --now forcicd-cd.timer
systemctl status --no-pager forcicd-cd.timer | head -5
REMOTE

echo "install-cd done. The watcher fires every 30s."
echo "To enable the kubetest pod roll, place a kubeconfig at"
echo "  /etc/forcicd/kubetest.kubeconfig on ${VM_NAME}."
