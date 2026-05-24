#!/usr/bin/env python3
"""Poll Forgejo for failed local builds; file a GitHub issue per
failed commit (deduped).

Runs on forcicd.g8.lo from a systemd timer (every 60s). For every
mirrored repo (ci/*), it looks at the most recent commit that has
any workflow run, and if that commit has at least one failed job
*and* no issue has been filed for it yet, opens a GitHub issue on
the corresponding github.com repo:

    title: "CI failure on <branch> @ <sha7>"
    body : failed job list + link to the forcicd run log + the
           github commit, labelled `ci-failure`.

Dedup is two-layered:
  1. a local state file of already-issued "<repo>@<sha>" keys, and
  2. a GitHub search for an existing open `ci-failure` issue
     mentioning the sha (so re-installs / state loss don't dupe).
"""

import json
import os
import sys
import urllib.error
import urllib.request
from base64 import b64encode
from urllib.parse import quote

FORGEJO_URL = os.environ.get("FORGEJO_URL", "http://localhost:3000")
FORGEJO_USER = os.environ.get("FORGEJO_ADMIN_USER", "ci")
ADMIN_PW_FILE = os.environ.get("ADMIN_PW_FILE", "/etc/forcicd/admin-password")
GH_TOKEN_FILE = os.environ.get("GH_TOKEN_FILE", "/etc/forcicd/github-token")
GH_OWNER = os.environ.get("GH_OWNER", "glennswest")
STATE_FILE = os.environ.get("ISSUE_STATE_FILE", "/var/lib/forcicd/issued-failures")
DASH = os.environ.get("FORCICD_PUBLIC_URL", "http://forcicd.g8.lo:3000")
LABEL = os.environ.get("CI_FAILURE_LABEL", "ci-failure")


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


PW = _read(ADMIN_PW_FILE)
TOKEN = _read(GH_TOKEN_FILE)


def forgejo(path):
    req = urllib.request.Request(f"{FORGEJO_URL}{path}")
    if PW:
        req.add_header("Authorization",
                       "Basic " + b64encode(f"{FORGEJO_USER}:{PW}".encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None


def gh(method, path, body=None):
    url = path if path.startswith("http") else f"https://api.github.com{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "forcicd-issue-bot",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or "null")
    except urllib.error.HTTPError as e:
        return e.code, None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return 0, None


def load_state():
    return set(filter(None, _read(STATE_FILE).splitlines()))


def append_state(key):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "a") as f:
        f.write(key + "\n")


def list_mirrors():
    """All Forgejo repos under the ci user."""
    out, page = [], 1
    while True:
        d = forgejo(f"/api/v1/repos/search?uid=0&limit=50&page={page}") or {}
        items = d.get("data") or []
        if not items:
            break
        out += [(r["name"], r["full_name"]) for r in items]
        if len(items) < 50:
            break
        page += 1
    return out


def latest_commit_runs(full):
    """Return (sha, branch, [failed_job_names], [all_job_names],
    run_number) for the newest commit that has runs, or None."""
    d = forgejo(f"/api/v1/repos/{full}/actions/tasks?limit=30") or {}
    runs = d.get("workflow_runs") or []
    if not runs:
        return None
    newest_sha = runs[0].get("head_sha")
    group = [r for r in runs if r.get("head_sha") == newest_sha]
    failed = [r.get("name") for r in group if r.get("status") == "failure"]
    allj = [r.get("name") for r in group]
    return {
        "sha": newest_sha,
        "branch": runs[0].get("head_branch"),
        "failed": failed,
        "all": allj,
        "run_number": runs[0].get("run_number"),
    }


def existing_issue(repo_full, sha7):
    """True if an open ci-failure issue already mentions this sha."""
    q = quote(f'repo:{repo_full} is:issue is:open label:{LABEL} {sha7}')
    code, body = gh("GET", f"/search/issues?q={q}&per_page=1")
    return bool(body and body.get("total_count", 0) > 0)


def ensure_label(repo_full):
    # Create the label once; ignore "already exists".
    gh("POST", f"/repos/{repo_full}/labels",
       {"name": LABEL, "color": "d73a4a",
        "description": "Local forcicd CI build failed"})


def file_issue(name, info):
    repo_full = f"{GH_OWNER}/{name}"
    sha = info["sha"] or ""
    sha7 = sha[:7]
    key = f"{name}@{sha}"

    # Claim the key up front (before any slow GitHub call) so a
    # concurrent run — e.g. a manual invocation racing the timer —
    # can't file a second issue for the same commit. We re-read and
    # CAS via O_EXCL on a per-key lock file.
    lockdir = os.path.dirname(STATE_FILE)
    os.makedirs(lockdir, exist_ok=True)
    lock = os.path.join(lockdir, ".lock-" + key.replace("/", "_"))
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
    except FileExistsError:
        return f"  = {name}@{sha7} (another worker is handling it)"

    if existing_issue(repo_full, sha7):
        append_state(key)  # record so we stop re-checking
        return f"  = {name}@{sha7} (issue already open)"

    ensure_label(repo_full)
    fjlog = f"{DASH}/{FORGEJO_USER}/{name}/actions/runs/{info['run_number']}"
    failed = "\n".join(f"- `{j}`" for j in info["failed"]) or "- (unknown)"
    title = f"CI failure on {info['branch']} @ {sha7}"
    body = (
        f"forcicd's local CI build failed for commit "
        f"[`{sha7}`](https://github.com/{repo_full}/commit/{sha}) "
        f"on `{info['branch']}`.\n\n"
        f"**Failed jobs:**\n{failed}\n\n"
        f"**Run log:** {fjlog}\n\n"
        f"_Filed automatically by forcicd. GitHub Actions is "
        f"disabled for this repo; forcicd is the authoritative CI._"
    )
    code, created = gh("POST", f"/repos/{repo_full}/issues",
                       {"title": title, "body": body, "labels": [LABEL]})
    if code in (200, 201) and created:
        append_state(key)
        return f"  + {name}@{sha7} -> issue #{created.get('number')}"
    return f"  ! {name}@{sha7} (issue create failed, HTTP {code})"


def main():
    if not PW:
        print("no forgejo admin password; cannot poll", file=sys.stderr); sys.exit(2)
    if not TOKEN:
        print("no github token; cannot file issues", file=sys.stderr); sys.exit(2)

    state = load_state()
    actions = []
    for name, full in list_mirrors():
        info = latest_commit_runs(full)
        if not info or not info["failed"]:
            continue
        key = f"{name}@{info['sha']}"
        if key in state:
            continue
        actions.append(file_issue(name, info))

    if actions:
        print("\n".join(actions))


if __name__ == "__main__":
    main()
