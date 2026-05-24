#!/usr/bin/env python3
# forcicd ops dashboard.
#
# Two views:
#
#   /          (default) — multi-project overview. All active GitHub
#                          repos in one table: latest CI status, open
#                          PRs, open issues, last push. Filterable by
#                          recency (default: last 30 days).
#   /local     — forcicd-specific: VM/container/runner/mirror/CD state.
#
# Refreshes client-side every 5–15 seconds depending on the view.

import http.client
import http.server
import json
import os
import socket
import threading
import time
import urllib.error
import urllib.request
from base64 import b64encode
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

# --- forcicd-local config -----------------------------------------
FORGEJO_URL = os.environ.get("FORGEJO_URL", "http://forgejo:3000")
REPO        = os.environ.get("FORGEJO_REPO", "ci/fastetcd")
ADMIN_USER  = os.environ.get("FORGEJO_ADMIN_USER", "ci")
ADMIN_PW_FILE = os.environ.get("ADMIN_PW_FILE", "/etc/forcicd/admin-password")
STATE_FILE  = os.environ.get("STATE_FILE", "/var/lib/forcicd/last-deployed")
DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")

# --- github config ------------------------------------------------
GH_TOKEN_FILE = os.environ.get("GH_TOKEN_FILE", "/etc/forcicd/github-token")
GH_API = "https://api.github.com"
# How many repos to pull from /user/repos. GitHub max is 100 per page.
GH_REPOS_PAGES = int(os.environ.get("GH_REPOS_PAGES", "5"))
# Overview defaults to repos active in the last 30 days.
GH_ACTIVE_DAYS = int(os.environ.get("GH_ACTIVE_DAYS", "30"))
# Which repos to include by affiliation. Default `owner` shows
# only repos you own (not the hundreds you can see via org
# membership). Set to "owner,collaborator,organization_member"
# to widen.
GH_AFFILIATION = os.environ.get("GH_AFFILIATION", "owner")
# Cache GitHub responses for 60s — we have rate limits and a lot of
# repos. The UI refresh is 15s; the cache cushion absorbs that.
GH_CACHE_SECS = int(os.environ.get("GH_CACHE_SECS", "60"))
# Label the failure-watcher uses; the issues grid flags these as
# auto-fix candidates.
LABEL_CI_FAILURE = os.environ.get("CI_FAILURE_LABEL", "ci-failure")


# ============================================================
# Forgejo / local-state helpers (unchanged from v1)
# ============================================================

def auth_header_forgejo() -> str | None:
    try:
        with open(ADMIN_PW_FILE) as f:
            pw = f.read().strip()
        if not pw:
            return None
        return "Basic " + b64encode(f"{ADMIN_USER}:{pw}".encode()).decode()
    except FileNotFoundError:
        return None


def get_forgejo(path: str) -> dict | None:
    req = urllib.request.Request(f"{FORGEJO_URL}{path}")
    hdr = auth_header_forgejo()
    if hdr:
        req.add_header("Authorization", hdr)
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            return json.loads(r.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None


def docker_ps() -> list[dict]:
    try:
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


def local_state() -> dict:
    out: dict = {"now": datetime.now(timezone.utc).isoformat(timespec="seconds")}

    ver = get_forgejo("/api/v1/version")
    out["forgejo_version"] = ver.get("version") if ver else None

    repo = get_forgejo(f"/api/v1/repos/{REPO}")
    if repo:
        out["mirror"] = {
            "branch": repo.get("default_branch"),
            "size_kb": repo.get("size"),
            "updated_at": repo.get("updated_at"),
            "html_url": repo.get("html_url"),
        }
    else:
        out["mirror"] = None

    runs = get_forgejo(f"/api/v1/repos/{REPO}/actions/tasks?limit=1") or {}
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

    green = get_forgejo(
        f"/api/v1/repos/{REPO}/actions/tasks?branch=main&status=success&limit=1"
    ) or {}
    g = (green.get("workflow_runs") or [None])[0]
    out["latest_green_sha"] = (g.get("head_sha") if g else None)

    try:
        with open(STATE_FILE) as f:
            out["last_deployed_sha"] = f.read().strip()
    except FileNotFoundError:
        out["last_deployed_sha"] = None

    if out["latest_green_sha"] and out["last_deployed_sha"]:
        out["in_sync"] = out["latest_green_sha"] == out["last_deployed_sha"]
    else:
        out["in_sync"] = None

    out["containers"] = [
        {
            "name": (c["Names"][0] if c.get("Names") else "")[1:],
            "image": c.get("Image"),
            "state": c.get("State"),
            "status": c.get("Status"),
        }
        for c in docker_ps()
    ]

    runners = get_forgejo("/api/v1/admin/runners")
    out["runners"] = [
        {
            "id": r.get("id"),
            "name": r.get("name"),
            "version": r.get("version"),
            "labels": [l.get("name") for l in (r.get("labels") or [])],
            "last_online": r.get("last_online"),
            "status": r.get("status"),
        }
        for r in (runners.get("runners") if runners else []) or []
    ]

    return out


# ============================================================
# GitHub helpers + overview
# ============================================================

_gh_token_cached = None

def gh_token() -> str | None:
    global _gh_token_cached
    if _gh_token_cached is None:
        try:
            with open(GH_TOKEN_FILE) as f:
                _gh_token_cached = f.read().strip() or None
        except FileNotFoundError:
            _gh_token_cached = ""
    return _gh_token_cached or None


def gh_request(path: str) -> tuple[int, list | dict | None, dict]:
    """GET against api.github.com; returns (status, json, headers)."""
    tok = gh_token()
    if not tok:
        return (0, None, {})
    url = path if path.startswith("http") else f"{GH_API}{path}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {tok}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "forcicd-dashboard",
    })
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return (r.status, json.loads(r.read()), dict(r.headers))
    except urllib.error.HTTPError as e:
        return (e.code, None, dict(e.headers))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return (0, None, {})


# Simple thread-safe TTL cache: { key: (expires_at, value) }
_cache: dict[str, tuple[float, object]] = {}
_cache_lock = threading.Lock()


def cached(key: str, ttl: int, producer) -> object:
    now = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and hit[0] > now:
            return hit[1]
    value = producer()
    with _cache_lock:
        _cache[key] = (now + ttl, value)
    return value


def gh_active_repos() -> list[dict]:
    """All owned repos pushed within the last GH_ACTIVE_DAYS days."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=GH_ACTIVE_DAYS)
    repos = []
    for page in range(1, GH_REPOS_PAGES + 1):
        status, body, _ = gh_request(
            f"/user/repos?per_page=100&sort=pushed&direction=desc"
            f"&affiliation={quote(GH_AFFILIATION)}&page={page}"
        )
        if status != 200 or not body:
            break
        for r in body:
            pushed = r.get("pushed_at")
            if not pushed:
                continue
            try:
                ts = datetime.fromisoformat(pushed.replace("Z", "+00:00"))
            except ValueError:
                continue
            if ts < cutoff:
                # /user/repos is sorted desc by pushed; everything
                # after this point is older too.
                return repos
            repos.append({
                "full_name": r.get("full_name"),
                "name": r.get("name"),
                "owner": (r.get("owner") or {}).get("login"),
                "pushed_at": pushed,
                "default_branch": r.get("default_branch") or "main",
                "open_issues_count": r.get("open_issues_count", 0),
                "html_url": r.get("html_url"),
                "private": r.get("private"),
                "fork": r.get("fork"),
                "archived": r.get("archived"),
            })
    return repos


def gh_repo_status(full_name: str, default_branch: str) -> dict:
    """Latest CI run + PR count for one repo. Cheap calls only."""
    out = {
        "ci_status": None, "ci_conclusion": None, "ci_url": None,
        "ci_started_at": None,
        "pr_count": 0,
    }
    # Latest workflow run on the default branch.
    status, body, _ = gh_request(
        f"/repos/{quote(full_name, safe='/')}/actions/runs"
        f"?branch={quote(default_branch)}&per_page=1"
    )
    if status == 200 and body:
        runs = body.get("workflow_runs") or []
        if runs:
            r = runs[0]
            out["ci_status"] = r.get("status")
            out["ci_conclusion"] = r.get("conclusion")
            out["ci_url"] = r.get("html_url")
            out["ci_started_at"] = r.get("run_started_at")
    # Open PR count via REST (the /search API has a 30/min limit
    # that the fan-out blows through; REST is 5000/hr). We ask for
    # one page of open PRs with a big per_page and count locally —
    # cheap and avoids search entirely.
    status, body, _ = gh_request(
        f"/repos/{quote(full_name, safe='/')}/pulls?state=open&per_page=100"
    )
    if status == 200 and isinstance(body, list):
        out["pr_count"] = len(body)
    return out


def forgejo_local_ci() -> dict[str, dict]:
    """Map repo-name → latest local Forgejo run status + log URL.

    The overview's GitHub badges show *github.com* CI; this is what
    *forcicd actually built locally*. Keyed by bare repo name (the
    mirror lives at ci/<name>)."""
    out: dict[str, dict] = {}
    page = 1
    while True:
        repos = get_forgejo(
            f"/api/v1/repos/search?uid=0&limit=50&page={page}"
        ) or {}
        items = repos.get("data") or []
        if not items:
            break
        for r in items:
            name = r.get("name")
            full = r.get("full_name")  # ci/<name>
            if not name or not full:
                continue
            tasks = get_forgejo(
                f"/api/v1/repos/{full}/actions/tasks?limit=1"
            ) or {}
            run = (tasks.get("workflow_runs") or [None])[0]
            if run:
                # The Forgejo UI addresses runs by their per-repo
                # `run_number` (the /actions/runs/<n> path), NOT the
                # global `id`. Using id 404s.
                out[name] = {
                    "local_status": run.get("status"),
                    "local_sha": (run.get("head_sha") or "")[:7],
                    "local_url": f"http://forcicd.g8.lo:3000/{full}/actions/runs/{run.get('run_number')}",
                }
            else:
                out[name] = {"local_status": None, "local_sha": None,
                             "local_url": f"http://forcicd.g8.lo:3000/{full}/actions"}
        if len(items) < 50:
            break
        page += 1
    return out


def overview() -> dict:
    def build():
        repos = gh_active_repos()
        local = forgejo_local_ci()
        # Fan out repo-detail calls in parallel; GitHub rate limit is
        # 5k req/h for an authed user, plenty of headroom for ~100 repos.
        rows = []
        with ThreadPoolExecutor(max_workers=8) as ex:
            futures = {
                ex.submit(gh_repo_status, r["full_name"], r["default_branch"]): r
                for r in repos
            }
            for fut in as_completed(futures):
                r = futures[fut]
                try:
                    detail = fut.result()
                except Exception:
                    detail = {}
                # Join local forcicd build status by bare repo name.
                loc = local.get(r["name"], {})
                rows.append({**r, **detail, **loc,
                             "mirrored": r["name"] in local})
        # Sort newest-pushed first.
        rows.sort(key=lambda r: r.get("pushed_at") or "", reverse=True)

        # Summary counts for the header.
        summary = {
            "total_active": len(rows),
            "ci_running": sum(1 for r in rows if r.get("ci_status") in ("queued", "in_progress")),
            "ci_failing": sum(1 for r in rows if r.get("ci_conclusion") == "failure"),
            "ci_passing": sum(1 for r in rows if r.get("ci_conclusion") == "success"),
            "mirrored": sum(1 for r in rows if r.get("mirrored")),
            "local_failing": sum(1 for r in rows if r.get("local_status") == "failure"),
            "local_passing": sum(1 for r in rows if r.get("local_status") == "success"),
            "open_prs": sum(r.get("pr_count", 0) for r in rows),
            "open_issues": sum(r.get("open_issues_count", 0) for r in rows),
        }
        return {
            "now": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "auth_ok": bool(gh_token()),
            "active_days": GH_ACTIVE_DAYS,
            "summary": summary,
            "rows": rows,
        }

    return cached("overview", GH_CACHE_SECS, build)


def _repo_open_issues(full_name: str) -> list[dict]:
    """Open issues (not PRs) for one repo via REST."""
    rows = []
    status, body, _ = gh_request(
        f"/repos/{quote(full_name, safe='/')}/issues"
        f"?state=open&sort=updated&direction=desc&per_page=50"
    )
    if status != 200 or not isinstance(body, list):
        return rows
    for it in body:
        if it.get("pull_request"):      # the issues endpoint includes PRs
            continue
        labels = [l.get("name") for l in (it.get("labels") or [])]
        rows.append({
            "repo": full_name,
            "number": it.get("number"),
            "title": it.get("title"),
            "labels": labels,
            "is_ci_failure": LABEL_CI_FAILURE in labels,
            "comments": it.get("comments", 0),
            "updated_at": it.get("updated_at"),
            "created_at": it.get("created_at"),
            "html_url": it.get("html_url"),
            "state": it.get("state"),
        })
    return rows


def issues() -> dict:
    """All open issues across active owned repos, newest first.
    Uses the REST issues endpoint per repo (5000/hr) rather than the
    /search API (30/min) so the fan-out doesn't hit the rate limit."""
    def build():
        repos = gh_active_repos()
        rows = []
        with ThreadPoolExecutor(max_workers=8) as ex:
            futures = [ex.submit(_repo_open_issues, r["full_name"]) for r in repos]
            for fut in as_completed(futures):
                try:
                    rows.extend(fut.result())
                except Exception:
                    pass
        rows.sort(key=lambda r: r.get("updated_at") or "", reverse=True)
        summary = {
            "total": len(rows),
            "ci_failures": sum(1 for r in rows if r["is_ci_failure"]),
            "repos": len({r["repo"] for r in rows}),
        }
        return {
            "now": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "auth_ok": bool(gh_token()),
            "summary": summary,
            "rows": rows,
        }
    return cached("issues", GH_CACHE_SECS, build)


# ============================================================
# HTML
# ============================================================

OVERVIEW_PAGE = """<!doctype html>
<html><head>
<meta charset="utf-8">
<title>forcicd — overview</title>
<style>
:root { color-scheme: dark; }
body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif;
       background: #0d1117; color: #c9d1d9; margin: 0; padding: 24px;
       max-width: 1400px; margin: 0 auto; }
header { display: flex; justify-content: space-between; align-items: baseline;
         margin-bottom: 16px; }
h1 { font-size: 18px; margin: 0; }
nav a { color: #58a6ff; margin-left: 12px; }
nav a.active { color: #c9d1d9; }
.subtitle { color: #8b949e; font-size: 12px; margin: 0 0 16px 0; }
.grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 8px;
        margin-bottom: 16px; }
.card { background: #161b22; border: 1px solid #30363d; border-radius: 6px;
        padding: 10px 14px; }
.card .label { color: #8b949e; font-size: 10px; text-transform: uppercase; }
.card .value { font-size: 22px; font-family: ui-monospace, monospace; }
.ok { color: #3fb950; } .bad { color: #f85149; } .warn { color: #d29922; }
.dim { color: #8b949e; }
table { width: 100%; border-collapse: collapse; font-family: ui-monospace, monospace; }
th, td { padding: 6px 8px; text-align: left; border-bottom: 1px solid #21262d; }
th { color: #8b949e; font-weight: normal; font-size: 11px; text-transform: uppercase;
     cursor: pointer; user-select: none; }
th:hover { color: #c9d1d9; }
a { color: #58a6ff; text-decoration: none; }
a:hover { text-decoration: underline; }
.search { background: #0d1117; border: 1px solid #30363d; color: #c9d1d9;
          padding: 4px 8px; border-radius: 4px; font: inherit; width: 200px; }
.pill { display: inline-block; padding: 1px 6px; border-radius: 10px;
        font-size: 11px; background: #21262d; }
.pill.ok { background: rgba(63, 185, 80, 0.18); color: #3fb950; }
.pill.bad { background: rgba(248, 81, 73, 0.18); color: #f85149; }
.pill.warn { background: rgba(210, 153, 34, 0.18); color: #d29922; }
.foot { color: #6e7681; font-size: 11px; margin-top: 24px; text-align: center; }
.controls { display: flex; gap: 12px; align-items: center; margin-bottom: 12px; }
</style></head>
<body>
<header>
  <h1>forcicd — overview</h1>
  <nav>
    <a href="/" class="active">overview</a>
    <a href="/issues">issues</a>
    <a href="/local">local CI</a>
    <a href="http://forcicd.g8.lo:3000">forgejo</a>
  </nav>
</header>
<p class="subtitle" id="subtitle">loading…</p>

<div class="grid" id="summary"></div>

<div class="controls">
  <input class="search" id="filter" placeholder="filter (name / status / owner)…">
  <label class="dim" style="cursor:pointer; user-select:none;">
    <input type="checkbox" id="hidenoci" checked> hide no-CI
  </label>
  <label class="dim" style="cursor:pointer; user-select:none;">
    <input type="checkbox" id="showgh"> show github ci
  </label>
  <span class="dim" id="resultcount"></span>
</div>

<table id="t">
  <thead><tr>
    <th data-k="full_name">repo</th>
    <th data-k="local_status">forcicd ci</th>
    <th data-k="ci_conclusion" class="ghcol" style="display:none">github ci</th>
    <th data-k="pr_count">PRs</th>
    <th data-k="open_issues_count">issues</th>
    <th data-k="pushed_at">last push</th>
    <th>flags</th>
  </tr></thead>
  <tbody id="rows"></tbody>
</table>

<p class="foot">data refreshes every 15s · last: <span id="now">—</span></p>

<script>
let DATA = {rows: [], summary: {}, active_days: 0};
let SORT = {k: "pushed_at", desc: true};

function pill(text, cls) {
  return `<span class="pill ${cls||''}">${text||'—'}</span>`;
}
function ciCell(r) {
  if (r.ci_status === "queued" || r.ci_status === "in_progress")
    return `<a href="${r.ci_url||'#'}">${pill(r.ci_status, 'warn')}</a>`;
  if (r.ci_conclusion === "success") return `<a href="${r.ci_url||'#'}">${pill('passing','ok')}</a>`;
  if (r.ci_conclusion === "failure") return `<a href="${r.ci_url||'#'}">${pill('failing','bad')}</a>`;
  if (r.ci_conclusion === "cancelled") return `<a href="${r.ci_url||'#'}">${pill('cancelled','dim')}</a>`;
  if (r.ci_conclusion === null && r.ci_status === null) return `<span class="dim">no ci</span>`;
  return `<a href="${r.ci_url||'#'}">${pill(r.ci_conclusion || '?', 'dim')}</a>`;
}
// forcicd-local build status. Click → the Forgejo run log.
function localCell(r) {
  if (!r.mirrored) return `<span class="dim">—</span>`;
  const u = r.local_url || '#';
  if (r.local_status === null)
    return `<a href="${u}">${pill('pending','dim')}</a>`;
  if (r.local_status === "success")
    return `<a href="${u}">${pill('built ✓','ok')}</a>`;
  if (r.local_status === "failure")
    return `<a href="${u}">${pill('built ✗','bad')}</a>`;
  if (r.local_status === "running" || r.local_status === "waiting")
    return `<a href="${u}">${pill(r.local_status,'warn')}</a>`;
  return `<a href="${u}">${pill(r.local_status||'?','dim')}</a>`;
}
function flagCell(r) {
  let f = [];
  if (r.private) f.push(pill('priv'));
  if (r.fork) f.push(pill('fork'));
  if (r.archived) f.push(pill('archived','dim'));
  return f.join(' ');
}
function ago(iso) {
  if (!iso) return '—';
  const ms = Date.now() - new Date(iso).getTime();
  const m = Math.floor(ms/60000); const h = Math.floor(m/60); const d = Math.floor(h/24);
  if (d > 0) return `${d}d ago`;
  if (h > 0) return `${h}h ago`;
  if (m > 0) return `${m}m ago`;
  return 'just now';
}
function render() {
  const s = DATA.summary;
  document.getElementById('summary').innerHTML = `
    <div class="card"><div class="label">active (${DATA.active_days}d)</div><div class="value">${s.total_active||0}</div></div>
    <div class="card"><div class="label">mirrored</div><div class="value">${s.mirrored||0}</div></div>
    <div class="card"><div class="label">built ✓</div><div class="value ok">${s.local_passing||0}</div></div>
    <div class="card"><div class="label">built ✗</div><div class="value bad">${s.local_failing||0}</div></div>
    <div class="card"><div class="label">pending</div><div class="value warn">${(s.mirrored||0)-(s.local_passing||0)-(s.local_failing||0)}</div></div>
    <div class="card"><div class="label">open issues</div><div class="value">${s.open_issues||0}</div></div>
  `;

  const q = document.getElementById('filter').value.toLowerCase();
  const hideNoCi = document.getElementById('hidenoci').checked;
  const showGh = document.getElementById('showgh').checked;
  // "Has CI" = there's a workflow to run locally. We detect that
  // from either a local run existing or github having had a run
  // (github's disabled now, but its history tells us a workflow
  // file is present in the repo).
  const hasCi = r => r.local_status !== undefined && r.local_status !== null
                  || !(r.ci_status === null && r.ci_conclusion === null);
  // Toggle the github column visibility.
  document.querySelectorAll('.ghcol').forEach(e => e.style.display = showGh ? '' : 'none');
  let rows = DATA.rows.filter(r =>
    (!hideNoCi || hasCi(r)) &&
    (!q || (r.full_name||'').toLowerCase().includes(q)
        || (r.local_status||'').toLowerCase().includes(q)
        || (r.ci_conclusion||'').toLowerCase().includes(q)
        || (r.owner||'').toLowerCase().includes(q)));
  rows.sort((a,b) => {
    const x = a[SORT.k] ?? ''; const y = b[SORT.k] ?? '';
    if (x < y) return SORT.desc ? 1 : -1;
    if (x > y) return SORT.desc ? -1 : 1;
    return 0;
  });
  document.getElementById('resultcount').textContent =
    rows.length === DATA.rows.length ? `${rows.length} repos` : `${rows.length} of ${DATA.rows.length}`;
  const showGhCol = document.getElementById('showgh').checked;
  document.getElementById('rows').innerHTML = rows.map(r => `
    <tr>
      <td><a href="${r.html_url}">${r.full_name}</a></td>
      <td>${localCell(r)}</td>
      <td class="ghcol" style="display:${showGhCol?'':'none'}">${ciCell(r)}</td>
      <td>${r.pr_count > 0 ? `<a href="${r.html_url}/pulls">${r.pr_count}</a>` : '<span class="dim">0</span>'}</td>
      <td>${r.open_issues_count > 0 ? `<a href="${r.html_url}/issues">${r.open_issues_count}</a>` : '<span class="dim">0</span>'}</td>
      <td class="dim">${ago(r.pushed_at)}</td>
      <td>${flagCell(r)}</td>
    </tr>`).join('');
  document.getElementById('subtitle').textContent =
    DATA.auth_ok
      ? `local-only CI · forcicd is authoritative · github actions disabled · ${DATA.active_days}d window`
      : 'NO GH TOKEN — put one at /etc/forcicd/github-token on the VM';
}
async function tick() {
  try {
    const d = await (await fetch('/overview.json')).json();
    DATA = d;
    document.getElementById('now').textContent = d.now;
    render();
  } catch (e) { /* keep last render */ }
}
document.querySelectorAll('th[data-k]').forEach(th => th.onclick = () => {
  const k = th.dataset.k;
  SORT = (SORT.k === k) ? {k, desc: !SORT.desc} : {k, desc: true};
  render();
});
document.getElementById('filter').oninput = render;
document.getElementById('hidenoci').onchange = render;
document.getElementById('showgh').onchange = render;
tick();
setInterval(tick, 15000);
</script>
</body></html>
"""

LOCAL_PAGE = """<!doctype html>
<html><head>
<meta charset="utf-8">
<title>forcicd — local CI</title>
<style>
:root { color-scheme: dark; }
body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif;
       background: #0d1117; color: #c9d1d9; margin: 0; padding: 24px;
       max-width: 1100px; margin: 0 auto; }
header { display: flex; justify-content: space-between; align-items: baseline;
         margin-bottom: 16px; }
h1 { font-size: 18px; margin: 0; }
nav a { color: #58a6ff; margin-left: 12px; }
nav a.active { color: #c9d1d9; }
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
<header>
  <h1>forcicd — local CI</h1>
  <nav>
    <a href="/">overview</a>
    <a href="/issues">issues</a>
    <a href="/local" class="active">local CI</a>
    <a href="http://forcicd.g8.lo:3000">forgejo</a>
  </nav>
</header>
<p class="subtitle">VM/containers/runner/mirror/CD on forcicd.g8.lo · auto-refresh 5s</p>
<div id="root">loading…</div>
<p class="foot">last data: <span id="now">—</span></p>
<script>
async function tick() {
  const d = await (await fetch('/local.json')).json();
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


ISSUES_PAGE = """<!doctype html>
<html><head>
<meta charset="utf-8">
<title>forcicd — issues</title>
<style>
:root { color-scheme: dark; }
body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif;
       background: #0d1117; color: #c9d1d9; margin: 0; padding: 24px;
       max-width: 1400px; margin: 0 auto; }
header { display: flex; justify-content: space-between; align-items: baseline;
         margin-bottom: 16px; }
h1 { font-size: 18px; margin: 0; }
nav a { color: #58a6ff; margin-left: 12px; }
nav a.active { color: #c9d1d9; }
.subtitle { color: #8b949e; font-size: 12px; margin: 0 0 16px 0; }
.grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-bottom: 16px; }
.card { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 10px 14px; }
.card .label { color: #8b949e; font-size: 10px; text-transform: uppercase; }
.card .value { font-size: 22px; font-family: ui-monospace, monospace; }
.bad { color: #f85149; } .ok { color: #3fb950; } .dim { color: #8b949e; }
table { width: 100%; border-collapse: collapse; font-family: ui-monospace, monospace; }
th, td { padding: 6px 8px; text-align: left; border-bottom: 1px solid #21262d; vertical-align: top; }
th { color: #8b949e; font-weight: normal; font-size: 11px; text-transform: uppercase; cursor: pointer; }
a { color: #58a6ff; text-decoration: none; } a:hover { text-decoration: underline; }
.search { background: #0d1117; border: 1px solid #30363d; color: #c9d1d9;
          padding: 4px 8px; border-radius: 4px; font: inherit; width: 240px; }
.controls { display: flex; gap: 12px; align-items: center; margin-bottom: 12px; }
.lbl { background: #21262d; border-radius: 10px; padding: 1px 7px; font-size: 11px; margin-right: 3px; }
.lbl.cifail { background: rgba(248,81,73,0.18); color: #f85149; }
.btn { background: #238636; color: #fff; border: 0; border-radius: 5px;
       padding: 4px 10px; font: inherit; cursor: pointer; }
.btn:hover { background: #2ea043; }
.btn:disabled { background: #30363d; color: #8b949e; cursor: default; }
.foot { color: #6e7681; font-size: 11px; margin-top: 24px; text-align: center; }
</style></head>
<body>
<header>
  <h1>forcicd — issues</h1>
  <nav>
    <a href="/">overview</a>
    <a href="/issues" class="active">issues</a>
    <a href="/local">local CI</a>
    <a href="http://forcicd.g8.lo:3000">forgejo</a>
  </nav>
</header>
<p class="subtitle" id="subtitle">loading…</p>
<div class="grid" id="summary"></div>
<div class="controls">
  <input class="search" id="filter" placeholder="filter (repo / title / label)…">
  <label class="dim" style="cursor:pointer"><input type="checkbox" id="cionly"> ci-failures only</label>
  <span class="dim" id="resultcount"></span>
</div>
<table id="t">
  <thead><tr>
    <th data-k="repo">repo</th>
    <th data-k="number">#</th>
    <th data-k="title">title</th>
    <th>labels</th>
    <th data-k="updated_at">updated</th>
    <th>action</th>
  </tr></thead>
  <tbody id="rows"></tbody>
</table>
<p class="foot">refreshes every 30s · last: <span id="now">—</span></p>
<script>
let DATA = {rows: [], summary: {}};
let SORT = {k: "updated_at", desc: true};
function ago(iso){ if(!iso) return '—'; const m=Math.floor((Date.now()-new Date(iso))/60000);
  const h=Math.floor(m/60), d=Math.floor(h/24);
  return d>0?`${d}d`:h>0?`${h}h`:m>0?`${m}m`:'now'; }
function labelsCell(r){
  return (r.labels||[]).map(l =>
    `<span class="lbl ${l===DATA.ci_label?'cifail':''}">${l}</span>`).join('');
}
async function fix(repo, number, btn){
  btn.disabled = true; btn.textContent = 'launching…';
  try {
    const res = await fetch('/fix', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({repo, number})});
    const j = await res.json();
    if (j.ok) { btn.textContent = 'worker: ' + (j.session||'started'); }
    else { btn.textContent = 'failed'; btn.disabled = false; alert(j.error||'launch failed'); }
  } catch(e) { btn.textContent='error'; btn.disabled=false; }
}
function render(){
  const s = DATA.summary;
  document.getElementById('summary').innerHTML = `
    <div class="card"><div class="label">open issues</div><div class="value">${s.total||0}</div></div>
    <div class="card"><div class="label">ci-failures</div><div class="value bad">${s.ci_failures||0}</div></div>
    <div class="card"><div class="label">repos</div><div class="value">${s.repos||0}</div></div>`;
  const q = document.getElementById('filter').value.toLowerCase();
  const ciOnly = document.getElementById('cionly').checked;
  let rows = DATA.rows.filter(r =>
    (!ciOnly || r.is_ci_failure) &&
    (!q || (r.repo||'').toLowerCase().includes(q)
        || (r.title||'').toLowerCase().includes(q)
        || (r.labels||[]).join(' ').toLowerCase().includes(q)));
  rows.sort((a,b)=>{const x=a[SORT.k]??'',y=b[SORT.k]??'';
    return (x<y?1:x>y?-1:0)*(SORT.desc?1:-1);});
  document.getElementById('resultcount').textContent =
    rows.length===DATA.rows.length?`${rows.length} issues`:`${rows.length} of ${DATA.rows.length}`;
  document.getElementById('rows').innerHTML = rows.map(r => `
    <tr>
      <td><a href="https://github.com/${r.repo}/issues">${r.repo}</a></td>
      <td><a href="${r.html_url}">#${r.number}</a></td>
      <td><a href="${r.html_url}">${(r.title||'').replace(/</g,'&lt;')}</a></td>
      <td>${labelsCell(r)}</td>
      <td class="dim">${ago(r.updated_at)}</td>
      <td>${r.is_ci_failure
        ? `<button class="btn" onclick="fix('${r.repo}',${r.number},this)">▶ auto-fix</button>`
        : '<span class="dim">—</span>'}</td>
    </tr>`).join('');
  document.getElementById('subtitle').textContent = DATA.auth_ok
    ? 'open issues across your repos · ci-failures get a one-click Claude auto-fix worker'
    : 'NO GH TOKEN on the VM';
}
async function tick(){
  try { const d = await (await fetch('/issues.json')).json();
    DATA = d; document.getElementById('now').textContent = d.now; render();
  } catch(e){}
}
document.querySelectorAll('th[data-k]').forEach(th => th.onclick = () => {
  const k = th.dataset.k; SORT = (SORT.k===k)?{k,desc:!SORT.desc}:{k,desc:true}; render();
});
document.getElementById('filter').oninput = render;
document.getElementById('cionly').onchange = render;
tick(); setInterval(tick, 30000);
</script>
</body></html>
"""


def launch_fix_worker(repo: str, number: int) -> dict:
    """Kick off the agent worker for repo#number. Delegates to the
    host helper /opt/forcicd/fix-worker.sh via the docker socket is
    overkill; instead the dashboard writes a request file that the
    host-side fix-dispatcher picks up. Keeps the dashboard container
    from needing pct/screen access."""
    import re
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo or "") or not isinstance(number, int):
        return {"ok": False, "error": "bad repo/number"}
    reqdir = os.environ.get("FIX_REQ_DIR", "/var/lib/forcicd/fix-requests")
    try:
        os.makedirs(reqdir, exist_ok=True)
        session = f"fix-{repo.split('/')[-1]}-{number}"
        req = os.path.join(reqdir, f"{session}.json")
        with open(req, "w") as f:
            json.dump({"repo": repo, "number": number, "session": session,
                       "requested_at": datetime.now(timezone.utc).isoformat()}, f)
        return {"ok": True, "session": session}
    except OSError as e:
        return {"ok": False, "error": str(e)}


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, body: bytes, ct: str, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path in ("/", "/index.html", "/overview"):
            self._send(OVERVIEW_PAGE.encode(), "text/html; charset=utf-8")
        elif self.path == "/issues":
            self._send(ISSUES_PAGE.encode(), "text/html; charset=utf-8")
        elif self.path == "/local":
            self._send(LOCAL_PAGE.encode(), "text/html; charset=utf-8")
        elif self.path == "/overview.json":
            self._send(json.dumps(overview()).encode(), "application/json")
        elif self.path == "/issues.json":
            data = issues()
            data["ci_label"] = LABEL_CI_FAILURE
            self._send(json.dumps(data).encode(), "application/json")
        elif self.path in ("/state.json", "/local.json"):
            self._send(json.dumps(local_state()).encode(), "application/json")
        elif self.path == "/healthz":
            self._send(b"ok", "text/plain")
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):  # noqa: N802
        if self.path == "/fix":
            length = int(self.headers.get("Content-Length", "0"))
            try:
                payload = json.loads(self.rfile.read(length) or "{}")
            except json.JSONDecodeError:
                payload = {}
            result = launch_fix_worker(payload.get("repo", ""),
                                       payload.get("number"))
            code = 200 if result.get("ok") else 400
            self._send(json.dumps(result).encode(), "application/json", code)
        else:
            self.send_response(404); self.end_headers()

    def log_message(self, *_a, **_k):
        pass


if __name__ == "__main__":
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", 8090), Handler)
    print("dashboard on :8090")
    srv.serve_forever()
