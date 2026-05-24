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
    repo=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('repo',''))" "${req}")
    number=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('number',''))" "${req}")
    session=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('session',''))" "${req}")
    [[ -n "${repo}" && -n "${number}" && -n "${session}" ]] || { mv "${req}" "${DONEDIR}/"; continue; }

    # Skip if a session by this name is already running.
    if screen -ls 2>/dev/null | grep -q "\.${session}[[:space:]]"; then
        echo "session ${session} already running; leaving request"
        continue
    fi

    echo "$(date -u +%FT%TZ) launching worker for ${repo}#${number} as ${session}"
    screen -dmS "${session}" bash -lc "'${WORKER}' '${repo}' '${number}' '${session}'"
    mv "${req}" "${DONEDIR}/${session}-$(date -u +%s).json"
done
