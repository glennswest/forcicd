#!/usr/bin/env python3
# forcicd ops dashboard — single-file HTTP server at :8090.
#
# Forgejo at :3000 is the GUI for code, workflows, runners, and the
# mirror. This dashboard is the *forcicd-specific* view: VM/container
# health, what the runner is doing, and CD state (last green build
# vs. last deployed SHA).
#
# Refreshes every 5s on the client; data is collected per-request.

import http.server
import json
import os
import socket
import subprocess
import urllib.error
import urllib.request
from base64 import b64encode
from datetime import datetime, timezone

FORGEJO_URL = os.environ.get("FORGEJO_URL", "http://forgejo:3000")
REPO        = os.environ.get("FORGEJO_REPO", "ci/fastetcd")
ADMIN_USER  = os.environ.get("FORGEJO_ADMIN_USER", "ci")
ADMIN_PW_FILE = os.environ.get("ADMIN_PW_FILE", "/etc/forcicd/admin-password")
STATE_FILE  = os.environ.get("STATE_FILE", "/var/lib/forcicd/last-deployed")
DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")


def auth_header() -> str | None:
    try:
        with open(ADMIN_PW_FILE) as f:
            pw = f.read().strip()
        if not pw:
            return None
        return "Basic " + b64encode(f"{ADMIN_USER}:{pw}".encode()).decode()
    except FileNotFoundError:
        return None


def get_json(path: str) -> dict | None:
    hdr = auth_header()
    req = urllib.request.Request(f"{FORGEJO_URL}{path}")
    if hdr:
        req.add_header("Authorization", hdr)
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            return json.loads(r.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None


def docker_ps() -> list[dict]:
    """Hit the docker socket directly — no docker CLI in the container."""
    try:
        import http.client
        conn = http.client.HTTPConnection("localhost", 80)
        conn.sock = socket.socket(socket.AF_UNIX)
        conn.sock.connect(DOCKER_SOCK)
        conn.request("GET", "/containers/json?all=true")
        resp = conn.getresponse()
        if resp.status != 200:
            return []
        return json.loads(resp.read())
    except (FileNotFoundError, ConnectionError, OSError):
        return []


def collect() -> dict:
    out: dict = {"now": datetime.now(timezone.utc).isoformat(timespec="seconds")}

    # Forgejo version
    ver = get_json("/api/v1/version")
    out["forgejo_version"] = ver.get("version") if ver else None

    # Mirror state
    repo = get_json(f"/api/v1/repos/{REPO}")
    if repo:
        out["mirror"] = {
            "branch": repo.get("default_branch"),
            "size_kb": repo.get("size"),
            "updated_at": repo.get("updated_at"),
            "html_url": repo.get("html_url"),
        }
    else:
        out["mirror"] = None

    # Latest workflow run
    runs = get_json(f"/api/v1/repos/{REPO}/actions/runs?limit=1") or {}
    latest = (runs.get("workflow_runs") or [None])[0]
    if latest:
        out["latest_run"] = {
            "id": latest.get("id"),
            "sha": (latest.get("head_sha") or "")[:12],
            "branch": latest.get("head_branch"),
            "status": latest.get("status"),
            "conclusion": latest.get("conclusion"),
            "started_at": latest.get("run_started_at"),
        }
    else:
        out["latest_run"] = None

    # Latest *green* run on main
    green = get_json(
        f"/api/v1/repos/{REPO}/actions/runs"
        f"?branch=main&status=success&limit=1"
    ) or {}
    g = (green.get("workflow_runs") or [None])[0]
    out["latest_green_sha"] = (g.get("head_sha") if g else None)

    # Last deployed (from the CD watcher's state file)
    try:
        with open(STATE_FILE) as f:
            out["last_deployed_sha"] = f.read().strip()
    except FileNotFoundError:
        out["last_deployed_sha"] = None

    # Drift
    if out["latest_green_sha"] and out["last_deployed_sha"]:
        out["in_sync"] = out["latest_green_sha"] == out["last_deployed_sha"]
    else:
        out["in_sync"] = None

    # Containers
    out["containers"] = [
        {
            "name": (c["Names"][0] if c.get("Names") else "")[1:],
            "image": c.get("Image"),
            "state": c.get("State"),
            "status": c.get("Status"),
        }
        for c in docker_ps()
    ]

    # Runners (Forgejo admin API)
    runners = get_json("/api/v1/admin/runners")
    if runners:
        out["runners"] = [
            {
                "id": r.get("id"),
                "name": r.get("name"),
                "version": r.get("version"),
                "labels": [l.get("name") for l in (r.get("labels") or [])],
                "last_online": r.get("last_online"),
                "status": r.get("status"),
            }
            for r in (runners.get("runners") or [])
        ]
    else:
        out["runners"] = []

    return out


PAGE = """<!doctype html>
<html><head>
<meta charset="utf-8">
<title>forcicd — ops dashboard</title>
<style>
:root { color-scheme: dark; }
body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif;
       background: #0d1117; color: #c9d1d9; margin: 0; padding: 24px;
       max-width: 1100px; margin: 0 auto; }
h1 { font-size: 18px; margin: 0 0 4px 0; }
h2 { font-size: 14px; text-transform: uppercase; letter-spacing: .05em;
     color: #8b949e; margin: 24px 0 8px 0; border-bottom: 1px solid #30363d;
     padding-bottom: 4px; }
.subtitle { color: #8b949e; font-size: 12px; margin: 0 0 16px 0; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.card { background: #161b22; border: 1px solid #30363d; border-radius: 6px;
        padding: 12px 16px; }
.card .label { color: #8b949e; font-size: 11px; text-transform: uppercase; }
.card .value { font-size: 20px; font-family: ui-monospace, monospace; }
.ok { color: #3fb950; } .bad { color: #f85149; } .warn { color: #d29922; }
table { width: 100%; border-collapse: collapse; font-family: ui-monospace, monospace; }
th, td { padding: 6px 8px; text-align: left; border-bottom: 1px solid #21262d; }
th { color: #8b949e; font-weight: normal; font-size: 11px; text-transform: uppercase; }
a { color: #58a6ff; }
.labels { display: flex; flex-wrap: wrap; gap: 4px; }
.lbl { background: #21262d; border-radius: 10px; padding: 2px 8px; font-size: 11px; }
.foot { color: #6e7681; font-size: 11px; margin-top: 24px; text-align: center; }
</style></head>
<body>
<h1>forcicd</h1>
<p class="subtitle">Local CI/CD for fastetcd · <a href="http://forcicd.g8.lo:3000">Forgejo at :3000</a> · auto-refresh 5s</p>
<div id="root">loading…</div>
<p class="foot">last data: <span id="now">—</span></p>
<script>
async function tick() {
  const d = await (await fetch('/state.json')).json();
  const sync = d.in_sync === true ? '<span class="ok">in sync</span>'
             : d.in_sync === false ? '<span class="warn">drift</span>'
             : '<span class="warn">—</span>';
  let html = `
    <h2>State</h2>
    <div class="grid">
      <div class="card"><div class="label">Forgejo</div>
        <div class="value">${d.forgejo_version || '<span class=bad>down</span>'}</div></div>
      <div class="card"><div class="label">Sync</div>
        <div class="value">${sync}</div></div>
      <div class="card"><div class="label">Latest green (main)</div>
        <div class="value">${(d.latest_green_sha||'—').slice(0,12)}</div></div>
      <div class="card"><div class="label">Last deployed</div>
        <div class="value">${(d.last_deployed_sha||'—').slice(0,12)}</div></div>
    </div>

    <h2>Containers</h2>
    <table><tr><th>name</th><th>image</th><th>state</th><th>status</th></tr>
    ${(d.containers||[]).map(c => `<tr>
      <td>${c.name}</td><td>${c.image}</td>
      <td class="${c.state==='running'?'ok':'bad'}">${c.state}</td>
      <td>${c.status}</td></tr>`).join('')}
    </table>

    <h2>Runners</h2>
    <table><tr><th>name</th><th>version</th><th>status</th><th>last online</th><th>labels</th></tr>
    ${(d.runners||[]).map(r => `<tr>
      <td>${r.name}</td><td>${r.version||'—'}</td>
      <td class="${r.status==='online'?'ok':'warn'}">${r.status||'?'}</td>
      <td>${r.last_online||'—'}</td>
      <td><div class="labels">${(r.labels||[]).map(l=>'<span class=lbl>'+l+'</span>').join('')}</div></td>
      </tr>`).join('')}
    </table>

    <h2>Mirror — ${d.mirror?.branch||'?'}</h2>
    <p>${d.mirror ? `<a href="${d.mirror.html_url}">${d.mirror.html_url}</a> · ${d.mirror.size_kb} KB · updated ${d.mirror.updated_at}` : 'no data'}</p>

    <h2>Latest workflow run</h2>
    <p>${d.latest_run ? `#${d.latest_run.id} <code>${d.latest_run.sha}</code> on <b>${d.latest_run.branch}</b> — ${d.latest_run.status}/${d.latest_run.conclusion||'…'} (started ${d.latest_run.started_at})` : 'no runs yet'}</p>
  `;
  document.getElementById('root').innerHTML = html;
  document.getElementById('now').textContent = d.now;
}
tick();
setInterval(tick, 5000);
</script>
</body></html>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(PAGE.encode())
        elif self.path == "/state.json":
            data = collect()
            body = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/healthz":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
        else:
            self.send_response(404); self.end_headers()

    def log_message(self, *_a, **_k):  # silence the default access log
        pass


if __name__ == "__main__":
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", 8090), Handler)
    print("dashboard on :8090")
    srv.serve_forever()
