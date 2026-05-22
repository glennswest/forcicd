#!/usr/bin/env bash
# Install Docker + bring up the Forgejo + runner stack on
# forcicd.g8.lo. Idempotent — re-running is safe (apt/dnf
# install skips, compose up is a noop if already running).
#
# Usage: ./scripts/install.sh

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

# Sync the compose file over.
scp -q "${REPO_ROOT}/forgejo/compose.yml" "${VM_SSH}:/tmp/compose.yml"

ssh "${VM_SSH}" 'sudo bash -se' <<'REMOTE'
set -euxo pipefail

# Install docker + compose-plugin (Fedora ships docker as moby-engine).
if ! command -v docker >/dev/null 2>&1; then
    dnf install -y moby-engine docker-compose
    systemctl enable --now docker
fi

# Open firewall for forgejo web (3000) + git SSH (2222).
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=3000/tcp || true
    firewall-cmd --permanent --add-port=2222/tcp || true
    firewall-cmd --reload || true
fi

# Stage the compose file.
install -d /etc/forcicd
install -m 0644 /tmp/compose.yml /etc/forcicd/compose.yml
rm -f /tmp/compose.yml

# Bring the stack up. `docker compose` is the v2 plugin; the
# moby-engine package on Fedora ships v1 as `docker-compose`, so
# accept either.
cd /etc/forcicd
if docker compose version >/dev/null 2>&1; then
    docker compose -f compose.yml up -d
else
    docker-compose -f compose.yml up -d
fi

# Wait for forgejo to answer on :3000.
for i in $(seq 1 60); do
    if curl -fsS --max-time 2 http://127.0.0.1:3000/api/v1/version >/dev/null 2>&1; then
        echo "forgejo: ready after ${i}*2s"
        exit 0
    fi
    sleep 2
done
echo "forgejo did not come up in 120s" >&2
docker logs forgejo 2>&1 | tail -20
exit 1
REMOTE

echo "install done — forgejo at http://forcicd.g8.lo:3000"
