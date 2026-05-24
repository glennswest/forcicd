#!/usr/bin/env bash
# Poll Forgejo for new successful workflow runs on the mirror's
# main branch. When the SHA advances past whatever's recorded in
# /var/lib/forcicd/last-deployed, fire deploy.sh.
#
# Designed to run from a systemd timer (every 30s). Idempotent —
# if last-deployed == latest-green, exits quietly.

set -uo pipefail

CONF=/etc/forcicd/deploy.env
[[ -f "${CONF}" ]] && source "${CONF}"
: "${FORGEJO_URL:=http://localhost:3000}"
: "${FORGEJO_REPO:=ci/fastetcd}"
: "${FORGEJO_BRANCH:=main}"
: "${FORGEJO_WORKFLOW:=ci.yml}"
# Deploy when every job matching this regex has succeeded for a
# given SHA AND none has failed. Default catches the three ubuntu
# entries in fastetcd's matrix: `test (ubuntu-latest / )`,
# `test (ubuntu-latest / iouring)`, `test (ubuntu-latest / wal-engine)`.
# We can't use the upstream `build release Linux binary` job as
# the gate because it `needs: [test]` and the macos entries always
# cancel here (no macos runner), causing it to never run.
: "${GATING_JOB_PATTERN:=^test \\(ubuntu-.*\\)$}"
: "${STATE_FILE:=/var/lib/forcicd/last-deployed}"
: "${DEPLOY_SCRIPT:=/opt/forcicd/deploy.sh}"
: "${ADMIN_PW_FILE:=/etc/forcicd/admin-password}"

install -d -m 0700 "$(dirname "${STATE_FILE}")"

if [[ ! -f "${ADMIN_PW_FILE}" ]]; then
    echo "no admin password at ${ADMIN_PW_FILE}; cannot poll Forgejo" >&2
    exit 2
fi

# Find the most-recent fully-green commit on the configured branch.
# Walk Forgejo's per-matrix-job listing newest→oldest, group by
# head_sha, and report the first SHA where every job matching
# GATING_JOB_PATTERN is `success` and none is `failure`.
LATEST=$(curl --silent --max-time 5 --fail \
    -u "ci:$(cat "${ADMIN_PW_FILE}")" \
    "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/actions/tasks?branch=${FORGEJO_BRANCH}&limit=60" \
    | GATING_JOB_PATTERN="${GATING_JOB_PATTERN}" python3 -c '
import json, os, re, sys
pat = re.compile(os.environ["GATING_JOB_PATTERN"])
runs = json.load(sys.stdin).get("workflow_runs", [])
# Group matching runs by SHA, preserving newest-first order.
seen, order = {}, []
for r in runs:
    if not pat.match(r.get("name", "")): continue
    sha = r["head_sha"]
    if sha not in seen:
        seen[sha] = {"success": 0, "failure": 0, "other": 0}
        order.append(sha)
    s = r.get("status", "other")
    seen[sha][s if s in ("success","failure") else "other"] += 1
# Report newest SHA where ≥1 matched, all green, none failed/other.
for sha in order:
    c = seen[sha]
    if c["success"] >= 1 and c["failure"] == 0 and c["other"] == 0:
        print(sha); break
' 2>/dev/null)

if [[ -z "${LATEST}" ]]; then
    exit 0   # no green build yet
fi

LAST=""
[[ -f "${STATE_FILE}" ]] && LAST=$(cat "${STATE_FILE}")

if [[ "${LATEST}" == "${LAST}" ]]; then
    exit 0   # already deployed
fi

echo "$(date -u +%FT%TZ) deploying ${LATEST} (was ${LAST:-none})"
if "${DEPLOY_SCRIPT}" "${LATEST}"; then
    echo "${LATEST}" > "${STATE_FILE}"
    echo "$(date -u +%FT%TZ) deploy ok"
else
    echo "$(date -u +%FT%TZ) deploy FAILED for ${LATEST}; not advancing state" >&2
    exit 1
fi
