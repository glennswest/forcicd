#!/usr/bin/env bash
# Drains /var/lib/forcicd/fix-requests/*.json — for each request,
# launches the auto-fix worker in a detached `screen` session so
# it can be attached live (`screen -r <session>`). Triggered by a
# systemd .path unit whenever a new request file appears.

set -uo pipefail

REQDIR="${FIX_REQ_DIR:-/var/lib/forcicd/fix-requests}"
DONEDIR="${REQDIR}/processed"
WORKER="${FIX_WORKER:-/opt/forcicd/fix-worker.sh}"
install -d -m 0755 "${REQDIR}" "${DONEDIR}"

shopt -s nullglob
for req in "${REQDIR}"/*.json; do
    read -r repo number session mode < <(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('repo',''), d.get('number',''), d.get('session',''), d.get('mode','fixit'))
" "${req}")
    [[ -n "${repo}" && -n "${number}" && -n "${session}" ]] || { mv "${req}" "${DONEDIR}/"; continue; }

    # Skip if a session by this name is already running.
    if screen -ls 2>/dev/null | grep -q "\.${session}[[:space:]]"; then
        echo "session ${session} already running; leaving request"
        continue
    fi

    echo "$(date -u +%FT%TZ) launching ${mode} worker for ${repo}#${number} as ${session}"
    screen -dmS "${session}" bash -lc "'${WORKER}' '${repo}' '${number}' '${session}' '${mode}'"
    mv "${req}" "${DONEDIR}/${session}-$(date -u +%s).json"
done
