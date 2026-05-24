#!/usr/bin/env bash
# Install the issue-driven auto-fix agent on forcicd.g8.lo:
#   - fix-dispatcher.sh + fix-worker.sh into /opt/forcicd
#   - systemd .path unit that fires the dispatcher when the
#     dashboard drops a fix request
#   - screen (for attachable agent sessions) if missing
#   - /etc/forcicd/fix.env (from sample) if not present
#
# After install, set CLAUDE_CMD + FIX_MOUNTS in /etc/forcicd/fix.env
# to wire in your Claude client + subscription.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

echo "==> copy agent files to ${VM_NAME}"
scp -q "${REPO_ROOT}/ci/fix-worker.sh" "${REPO_ROOT}/ci/fix-dispatcher.sh" \
    "${REPO_ROOT}/ci/fix-env.sh" \
    "${REPO_ROOT}/ci/forcicd-fixd.service" "${REPO_ROOT}/ci/forcicd-fixd.timer" \
    "${REPO_ROOT}/ci/fix.env.sample" \
    "${VM_SSH}:/tmp/"

ssh "${VM_SSH}" 'sudo bash -se' <<'REMOTE'
set -euo pipefail
# The worker clones + posts from the host, so it needs git/curl/
# screen there (docker provides the per-repo toolchain inside).
for pkg in screen git; do
    command -v "${pkg}" >/dev/null 2>&1 || dnf install -y "${pkg}"
done
install -d -m 0755 /opt/forcicd /var/lib/forcicd/fix-requests \
    /var/lib/forcicd/fix-workspaces /var/lib/forcicd/fix-logs
install -m 0755 /tmp/fix-worker.sh /opt/forcicd/fix-worker.sh
install -m 0755 /tmp/fix-dispatcher.sh /opt/forcicd/fix-dispatcher.sh
install -m 0755 /tmp/fix-env.sh /opt/forcicd/fix-env.sh
install -m 0644 /tmp/forcicd-fixd.service /etc/systemd/system/forcicd-fixd.service
install -m 0644 /tmp/forcicd-fixd.timer   /etc/systemd/system/forcicd-fixd.timer
[ -f /etc/forcicd/fix.env ] || install -m 0644 /tmp/fix.env.sample /etc/forcicd/fix.env
rm -f /tmp/fix-worker.sh /tmp/fix-dispatcher.sh /tmp/fix-env.sh \
      /tmp/forcicd-fixd.service /tmp/forcicd-fixd.timer /tmp/fix.env.sample
# Drop any prior .path unit (replaced by a timer — the .path looped
# because the dispatcher modifies the dir it watches).
systemctl disable --now forcicd-fixd.path 2>/dev/null || true
rm -f /etc/systemd/system/forcicd-fixd.path
systemctl daemon-reload
systemctl enable --now forcicd-fixd.timer
systemctl status --no-pager forcicd-fixd.timer | head -4
REMOTE

echo
echo "install-fix-agent done."
echo "Next: edit /etc/forcicd/fix.env on ${VM_NAME} — set CLAUDE_CMD"
echo "and FIX_MOUNTS to wire in your Claude client + subscription."
echo "Then click ▶ auto-fix on a ci-failure issue in the dashboard."
