#!/usr/bin/env bash
# Least-privilege app-deploy for a consumer repo (forcicd#1).
#
# Deploys target the app's OWN LXC/VM directly — never the Proxmox
# host. The CT/VM is provisioned once out of band; CI only updates
# the running app, and only through `cigate`: a busybox-style Rust
# binary exposing a fixed CI verb set and nothing else.
#
# Each repo gets its OWN dedicated key + repo-scoped secret, and
# can only act on its own target host. No shared/org-wide creds.
#
# Steps:
#   1. build the static cigate binary in a forcicd runner container
#   2. install cigate + per-app policy on the target
#   3. mint a dedicated key, authorize it on the target restricted
#      to command="cigate",from="<runner IP>"
#   4. register the private key as a REPO-SCOPED Forgejo secret
#
# Usage: ./scripts/install-app-deploy.sh <repo> <target-host> [user]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

REPO_NAME="${1:?usage: install-app-deploy.sh <repo> <target-host> [user]}"
TARGET_HOST="${2:?missing target host - the app LXC or VM}"
TARGET_USER="${3:-root}"
TARGET="${TARGET_USER}@${TARGET_HOST}"
: "${LOCAL_REGISTRY:=forcicd.g8.lo:5000}"
RUNNER_IMAGE="${LOCAL_REGISTRY}/forcicd-runner-ubuntu22:latest"
PW_FILE="${REPO_ROOT}/build/admin-password"
[[ -f "${PW_FILE}" ]] || { echo "run bootstrap.sh first" >&2; exit 2; }
PW=$(cat "${PW_FILE}")
RUNNER_IP="${RUNNER_IP:-${VM_IP}}"

# ---- 1. build cigate (static musl) in a runner container ---------
echo "==> building cigate on ${VM_NAME} (forcicd does the build)"
ssh "${VM_SSH}" 'install -d -m 0755 /tmp/cigate-src/src'
scp -q "${REPO_ROOT}/deploy/gate/Cargo.toml"  "${VM_SSH}:/tmp/cigate-src/Cargo.toml"
scp -q "${REPO_ROOT}/deploy/gate/src/main.rs" "${VM_SSH}:/tmp/cigate-src/src/main.rs"
BUILD='rustup target add x86_64-unknown-linux-musl >/dev/null 2>&1; cargo build --release --target x86_64-unknown-linux-musl 2>&1 | tail -3'
ssh "${VM_SSH}" "chmod -R a+rwX /tmp/cigate-src && sudo docker run --rm --security-opt label=disable -v /tmp/cigate-src:/work -w /work ${RUNNER_IMAGE} bash -lc '${BUILD}'"
ssh "${VM_SSH}" 'sudo cp /tmp/cigate-src/target/x86_64-unknown-linux-musl/release/cigate /tmp/cigate'

# ---- 2. install cigate + policy on the target --------------------
echo "==> installing cigate + policy on ${TARGET}"
ssh "${VM_SSH}" 'sudo cat /tmp/cigate' | ssh "${TARGET}" 'cat > /usr/local/bin/cigate && chmod 0755 /usr/local/bin/cigate'
scp -q "${REPO_ROOT}/deploy/gate.conf.sample" "${TARGET}:/tmp/gate.conf.sample"
ssh "${TARGET}" 'set -e
    install -d -m 0755 /etc/forcicd-deploy /var/lib/forcicd-deploy
    [ -f /etc/forcicd-deploy/gate.conf ] || install -m 0644 /tmp/gate.conf.sample /etc/forcicd-deploy/gate.conf
    touch /var/log/forcicd-deploy-gate.log
    rm -f /tmp/gate.conf.sample'

# ---- 3. mint + authorize a dedicated, restricted key -------------
echo "==> minting + authorizing a per-repo deploy key for ${REPO_NAME}"
KEYDIR="${REPO_ROOT}/build/deploy-keys"; mkdir -p "${KEYDIR}"; chmod 700 "${KEYDIR}"
KEY="${KEYDIR}/${REPO_NAME}"
[[ -f "${KEY}" ]] || ssh-keygen -t ed25519 -N '' -C "cigate/${REPO_NAME}" -f "${KEY}" >/dev/null

# Build the restricted authorized_keys line locally, push it as a
# file (avoids fragile nested quoting over ssh).
OPTS="command=\"/usr/local/bin/cigate\",from=\"${RUNNER_IP}\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding"
PUBKEY=$(cat "${KEY}.pub")
printf '%s %s\n' "${OPTS}" "${PUBKEY}" > "${KEYDIR}/${REPO_NAME}.authline"
scp -q "${KEYDIR}/${REPO_NAME}.authline" "${TARGET}:/tmp/forcicd.authline"
TAG="cigate/${REPO_NAME}"
ssh "${TARGET}" "install -d -m 0700 ~/.ssh; touch ~/.ssh/authorized_keys; \
    grep -vF '${TAG}' ~/.ssh/authorized_keys > ~/.ssh/ak.new || true; \
    cat /tmp/forcicd.authline >> ~/.ssh/ak.new; \
    mv ~/.ssh/ak.new ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; \
    rm -f /tmp/forcicd.authline"

# ---- 4. repo-scoped Forgejo secret -------------------------------
echo "==> registering DEPLOY_KEY (repo-scoped) on ci/${REPO_NAME}"
KEYDATA=$(python3 -c 'import json,sys; print(json.dumps({"data": open(sys.argv[1]).read()}))' "${KEY}")
CODE=$(curl -s -o /dev/null -w '%{http_code}' -u "ci:${PW}" -X PUT \
    "http://forcicd.g8.lo:3000/api/v1/repos/ci/${REPO_NAME}/actions/secrets/DEPLOY_KEY" \
    -H 'Content-Type: application/json' -d "${KEYDATA}")
if [[ "${CODE}" == "201" || "${CODE}" == "204" ]]; then
    echo "    DEPLOY_KEY set on ci/${REPO_NAME}"
else
    echo "    failed to set secret HTTP ${CODE} - is ci/${REPO_NAME} mirrored?" >&2
    exit 4
fi

echo
echo "app-deploy ready: ${REPO_NAME} -> ${TARGET}. Nothing touches pve."
echo "  gate    /usr/local/bin/cigate on the target  [only CI verbs]"
echo "  policy  /etc/forcicd-deploy/gate.conf on the target"
echo "  key     forced-command cigate, from=${RUNNER_IP}, repo-scoped"
echo "  secret  DEPLOY_KEY on ci/${REPO_NAME} only"
echo "Deploy from CI: see deploy/deploy.example.yml"
