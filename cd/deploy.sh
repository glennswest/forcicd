#!/usr/bin/env bash
# Build a fastetcd container from a Forgejo workflow artifact and
# push it to the local registry, then roll the kubetest etcd pod.
# Runs on forcicd.g8.lo (the VM has docker + LAN access to the
# registry and kubetest's API server).
#
# Inputs:
#   $1   SHA of the workflow run to deploy (taken from Forgejo API)
#
# Side effects:
#   - pulls the build-linux-binary artifact for ${SHA}
#   - builds + pushes ${LOCAL_REGISTRY}/fastetcd:${SHA} (+ :latest)
#   - kubectl rollout: sets the kubetest etcd pod's image and
#     forces a new pod
#
# This script is intentionally *not* clever. The watcher
# (watcher.sh) calls it once per new green build; idempotency
# is handled there.

set -euo pipefail

SHA="${1:?usage: deploy.sh <sha>}"

# Forcicd-VM-local config — overridable via /etc/forcicd/deploy.env
CONF=/etc/forcicd/deploy.env
[[ -f "${CONF}" ]] && source "${CONF}"
: "${LOCAL_REGISTRY:=fastregistry.g10.lo}"
: "${FORGEJO_URL:=http://forgejo:3000}"   # accessible from compose net
: "${FORGEJO_REPO:=ci/fastetcd}"
: "${IMAGE_NAME:=fastetcd}"
: "${KUBETEST_HOST:=kubetest.g8.lo}"
: "${KUBETEST_NS:=fastetcd}"
: "${KUBETEST_OBJ:=statefulset/fastetcd}"
: "${KUBETEST_CONTAINER:=fastetcd}"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

IMAGE_TAG="${LOCAL_REGISTRY}/${IMAGE_NAME}:${SHA}"
LATEST_TAG="${LOCAL_REGISTRY}/${IMAGE_NAME}:latest"

echo "==> fetch artifact for ${SHA}"
# Find the latest successful workflow run for SHA, then the
# build-linux-binary artifact, then download it. Forgejo's
# artifact API mirrors GitHub's: /api/v1/repos/{owner}/{repo}/actions/artifacts
curl --silent --max-time 30 --fail-with-body \
    -u "ci:$(cat /etc/forcicd/admin-password)" \
    "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/actions/artifacts?name=fastetcd-linux-x86_64" \
    -o "${WORK}/artifacts.json"

ARTIFACT_ID=$(python3 -c '
import json, sys, os
sha = os.environ["SHA"]
d = json.load(open(sys.argv[1]))
runs = d.get("artifacts", [])
for a in runs:
    # workflow_run.head_sha is the canonical match
    if a.get("workflow_run", {}).get("head_sha") == sha:
        print(a["id"]); break
' "${WORK}/artifacts.json")

if [[ -z "${ARTIFACT_ID}" ]]; then
    echo "no artifact found for SHA ${SHA}" >&2
    exit 3
fi

curl --silent --max-time 120 --fail-with-body --location \
    -u "ci:$(cat /etc/forcicd/admin-password)" \
    "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/actions/artifacts/${ARTIFACT_ID}/zip" \
    -o "${WORK}/artifact.zip"
( cd "${WORK}" && unzip -q artifact.zip )
chmod +x "${WORK}/fastetcd"

echo "==> build ${IMAGE_TAG}"
cat >"${WORK}/Dockerfile" <<'DOCKERFILE'
FROM scratch
COPY fastetcd /fastetcd
ENTRYPOINT ["/fastetcd"]
DOCKERFILE
docker build -t "${IMAGE_TAG}" -t "${LATEST_TAG}" "${WORK}"

echo "==> push ${IMAGE_TAG} + ${LATEST_TAG}"
docker push "${IMAGE_TAG}"
docker push "${LATEST_TAG}"

echo "==> roll ${KUBETEST_OBJ} on ${KUBETEST_HOST}"
# kubeconfig for the kubetest cluster lives on the VM at
# /etc/forcicd/kubetest.kubeconfig (operator-installed once).
KCFG=/etc/forcicd/kubetest.kubeconfig
if [[ ! -f "${KCFG}" ]]; then
    echo "  skipping rollout: ${KCFG} not present" >&2
    echo "  (drop a kubeconfig there to enable the CD half)" >&2
    exit 0
fi
kubectl --kubeconfig="${KCFG}" -n "${KUBETEST_NS}" \
    set image "${KUBETEST_OBJ}" "${KUBETEST_CONTAINER}=${IMAGE_TAG}"
kubectl --kubeconfig="${KCFG}" -n "${KUBETEST_NS}" \
    rollout status "${KUBETEST_OBJ}" --timeout=2m

echo "deploy ok: ${SHA} live on ${KUBETEST_HOST}"
