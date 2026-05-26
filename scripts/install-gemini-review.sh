#!/usr/bin/env bash
# Install the Gemini code-review watcher on forcicd.g8.lo:
#   - install the Gemini CLI (@google/gemini-cli) + node if missing
#   - place the AI Studio API key at /etc/forcicd/gemini-key (0600)
#   - gemini-review.py into /opt/forcicd
#   - systemd timer (every 60s) that reviews each new pushed commit
#     and files findings as LOCAL Forgejo issues (4 viewpoints)
#
# The API key is YOUR secret — it never lives in the repo. Provide it
# one of two ways:
#   GEMINI_API_KEY=AIza... ./scripts/install-gemini-review.sh
#   # ...or drop it in build/gemini-key (gitignored) first.
#
# Requires the Forgejo admin password (build/admin-password, from
# bootstrap.sh) so the reviewer can read mirrors + file issues.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

# ---- resolve the API key -----------------------------------------
KEY="${GEMINI_API_KEY:-}"
if [[ -z "${KEY}" && -f "${REPO_ROOT}/build/gemini-key" ]]; then
    KEY="$(tr -d '\r\n' < "${REPO_ROOT}/build/gemini-key")"
fi
if [[ -z "${KEY}" ]]; then
    echo "No Gemini API key. Set GEMINI_API_KEY=... or put it in" >&2
    echo "  ${REPO_ROOT}/build/gemini-key  (gitignored), then re-run." >&2
    echo "Get one at https://aistudio.google.com/apikey" >&2
    exit 2
fi

echo "==> install gemini CLI + place key on ${VM_NAME}"
# Key over stdin (never on the command line / process list).
printf '%s' "${KEY}" | ssh "${VM_SSH}" 'sudo bash -se' <<'REMOTE'
set -euo pipefail
install -d -m 0755 /etc/forcicd
umask 077
cat > /etc/forcicd/gemini-key
chmod 600 /etc/forcicd/gemini-key
umask 022
# Node + the Gemini CLI (idempotent).
if ! command -v gemini >/dev/null 2>&1; then
    command -v node >/dev/null 2>&1 || dnf install -y nodejs npm
    npm install -g @google/gemini-cli >/dev/null 2>&1
fi
echo "gemini: $(command -v gemini || echo MISSING) ($(gemini --version 2>/dev/null || echo '?'))"
REMOTE

echo "==> copy reviewer + unit files"
scp -q "${REPO_ROOT}/ci/gemini-review.py" \
    "${REPO_ROOT}/ci/forcicd-gemini.service" \
    "${REPO_ROOT}/ci/forcicd-gemini.timer" \
    "${VM_SSH}:/tmp/"

ssh "${VM_SSH}" 'sudo bash -se' <<'REMOTE'
set -euo pipefail
install -d -m 0755 /opt/forcicd /var/lib/forcicd
install -m 0755 /tmp/gemini-review.py /opt/forcicd/gemini-review.py
install -m 0644 /tmp/forcicd-gemini.service /etc/systemd/system/forcicd-gemini.service
install -m 0644 /tmp/forcicd-gemini.timer   /etc/systemd/system/forcicd-gemini.timer
rm -f /tmp/gemini-review.py /tmp/forcicd-gemini.service /tmp/forcicd-gemini.timer
systemctl daemon-reload
systemctl enable --now forcicd-gemini.timer
systemctl status --no-pager forcicd-gemini.timer | head -4
REMOTE

echo
echo "install-gemini-review done."
echo "Each new pushed commit on a mirror is now reviewed by Gemini;"
echo "findings open LOCAL Forgejo issues (label '${GEMINI_LABEL:-gemini-review}')"
echo "visible in the dashboard with the ▶ auto-fix button."
echo "Run once now:  ssh ${VM_SSH} 'sudo systemctl start forcicd-gemini.service'"
