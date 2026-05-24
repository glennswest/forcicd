#!/usr/bin/env bash
# Install the build-failure → GitHub-issue watcher on forcicd.g8.lo.
# A systemd timer runs ci/issue-on-failure.sh every 60s; when a
# mirrored repo's latest commit has a failed local build and no
# open ci-failure issue exists for it, an issue is filed on the
# corresponding github.com repo.
#
# Requires the GitHub token at /etc/forcicd/github-token (the
# dashboard/bulk-mirror setup already places it) with `repo` scope.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

echo "==> copy issue watcher + unit files to ${VM_NAME}"
scp -q "${REPO_ROOT}/ci/issue-on-failure.sh" \
    "${REPO_ROOT}/ci/forcicd-issues.service" \
    "${REPO_ROOT}/ci/forcicd-issues.timer" \
    "${VM_SSH}:/tmp/"

ssh "${VM_SSH}" 'sudo bash -se' <<REMOTE
set -euo pipefail
install -d -m 0755 /opt/forcicd /var/lib/forcicd
install -m 0755 /tmp/issue-on-failure.sh /opt/forcicd/issue-on-failure.sh
install -m 0644 /tmp/forcicd-issues.service /etc/systemd/system/forcicd-issues.service
install -m 0644 /tmp/forcicd-issues.timer   /etc/systemd/system/forcicd-issues.timer
rm -f /tmp/issue-on-failure.sh /tmp/forcicd-issues.service /tmp/forcicd-issues.timer
systemctl daemon-reload
systemctl enable --now forcicd-issues.timer
systemctl status --no-pager forcicd-issues.timer | head -4
REMOTE

echo "install-ci-issues done. Failed local builds now open github issues"
echo "(labelled '${CI_FAILURE_LABEL:-ci-failure}') on ${UPSTREAM_REPO_OWNER:-glennswest}/<repo>."
