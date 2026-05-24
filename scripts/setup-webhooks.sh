#!/usr/bin/env bash
# Wire up active GitHub callbacks (OpenShift-style webhooks) so
# forcicd never polls the GitHub API:
#   1. run ngrok on the forcicd VM to expose the dashboard (:80)
#      at a public https URL (GitHub can reach it; no inbound holes)
#   2. register a webhook on each mirrored repo pointing at
#      <public>/webhook/github, HMAC-signed with the shared secret,
#      for push / issues / pull_request / release events
#
# forcicd → GitHub stays push (issues/releases). GitHub → forcicd
# is now push too (webhooks). Polling: gone.
#
# Prereqs on the VM: an ngrok authtoken at /etc/forcicd/ngrok.token
# (free tier is fine). Usage:
#   ./scripts/setup-webhooks.sh                 # all mirrored repos
#   ./scripts/setup-webhooks.sh qregistry ...   # specific repos
#   PUBLIC_URL=https://my.tunnel ./scripts/setup-webhooks.sh
#       (skip ngrok; use an ingress/tunnel you already run)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

PW_FILE="${REPO_ROOT}/build/admin-password"
[[ -f "${PW_FILE}" ]] || { echo "run bootstrap.sh first" >&2; exit 2; }
PW=$(cat "${PW_FILE}")
GH_OWNER="${UPSTREAM_REPO_OWNER:-glennswest}"

TOKEN=$(ssh "${VM_SSH}" 'sudo cat /etc/forcicd/github-token' | tr -d '\r\n')
SECRET=$(ssh "${VM_SSH}" 'sudo cat /etc/forcicd/webhook-secret' | tr -d '\r\n')
[[ -n "${TOKEN}" && -n "${SECRET}" ]] || { echo "missing github-token/webhook-secret on VM" >&2; exit 3; }

# ---- 1. public URL (ngrok unless PUBLIC_URL given) ---------------
PUBLIC_URL="${PUBLIC_URL:-}"
if [[ -z "${PUBLIC_URL}" ]]; then
    echo "==> starting ngrok on ${VM_NAME} to expose the dashboard (:80)"
    ssh "${VM_SSH}" 'sudo bash -se' <<'REMOTE'
set -e
if ! command -v ngrok >/dev/null 2>&1; then
    curl -sSL https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz \
        | tar -xz -C /usr/local/bin ngrok
fi
if [ -f /etc/forcicd/ngrok.token ]; then
    ngrok config add-authtoken "$(cat /etc/forcicd/ngrok.token)" >/dev/null 2>&1 || true
fi
# Run ngrok as a transient unit pointing at the dashboard on :80.
systemctl is-active --quiet forcicd-ngrok 2>/dev/null || \
  systemd-run --unit=forcicd-ngrok --collect \
    /usr/local/bin/ngrok http 80 --log=stdout >/dev/null 2>&1 || true
sleep 4
REMOTE
    PUBLIC_URL=$(ssh "${VM_SSH}" "curl -s http://127.0.0.1:4040/api/tunnels" \
        | python3 -c 'import sys,json; ts=json.load(sys.stdin).get("tunnels",[]); print(next((t["public_url"] for t in ts if t["public_url"].startswith("https")), ""))' 2>/dev/null)
fi
[[ -n "${PUBLIC_URL}" ]] || { echo "no public URL (ngrok not up? set PUBLIC_URL=)" >&2; exit 4; }
HOOK="${PUBLIC_URL%/}/webhook/github"
echo "==> webhook endpoint: ${HOOK}"

# ---- 2. which repos -----------------------------------------------
if [[ $# -ge 1 ]]; then
    REPOS=$(printf '%s\n' "$@")
else
    REPOS=$(curl -s -u "ci:${PW}" \
        "http://forcicd.g8.lo:3000/api/v1/repos/search?uid=0&limit=200" \
        | python3 -c 'import sys,json; [print(r["name"]) for r in json.load(sys.stdin).get("data",[])]')
fi

# ---- 3. register (or update) the webhook per repo ----------------
gh_api() { curl -s -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json" "$@"; }

reg() {
    local name="$1" full="${GH_OWNER}/$1"
    local cfg
    cfg=$(python3 -c "import json,sys; print(json.dumps({
        'name':'web','active':True,
        'events':['push','issues','pull_request','release'],
        'config':{'url':sys.argv[1],'content_type':'json','secret':sys.argv[2],'insecure_ssl':'0'}}))" \
        "${HOOK}" "${SECRET}")
    # Find an existing forcicd hook (same URL host) to update.
    local hid
    hid=$(gh_api "https://api.github.com/repos/${full}/hooks" \
        | python3 -c "import sys,json
try: hooks=json.load(sys.stdin)
except Exception: hooks=[]
print(next((str(h['id']) for h in hooks if isinstance(h,dict) and 'webhook/github' in (h.get('config') or {}).get('url','')), ''))" 2>/dev/null)
    local code
    if [[ -n "${hid}" ]]; then
        code=$(gh_api -o /dev/null -w '%{http_code}' -X PATCH \
            "https://api.github.com/repos/${full}/hooks/${hid}" -d "${cfg}")
        echo "  ~ ${name} (updated hook ${hid}, HTTP ${code})"
    else
        code=$(gh_api -o /dev/null -w '%{http_code}' -X POST \
            "https://api.github.com/repos/${full}/hooks" -d "${cfg}")
        echo "  + ${name} (created hook, HTTP ${code})"
    fi
}

echo "==> registering webhooks on $(printf '%s\n' "${REPOS}" | grep -c .) repos"
while IFS= read -r r; do [[ -n "${r}" ]] && reg "${r}"; done <<< "${REPOS}"

cat <<EOF

webhooks wired. GitHub now pushes push/issues/pull_request/release
events to ${HOOK} (HMAC-signed). forcicd reacts instantly — no
polling. Keep ngrok up: 'systemctl status forcicd-ngrok' on the VM.
EOF
