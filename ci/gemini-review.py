#!/usr/bin/env python3
"""Gemini code review on every push → local Forgejo issues.

Runs on forcicd.g8.lo from a systemd timer (every 60s, same proven
pattern as issue-on-failure.py — polling the *local* Forgejo is
cheap; we never poll GitHub). For each mirrored repo it finds the
newest commit not yet reviewed, fetches that commit's diff from
Forgejo, and asks the **Gemini CLI** to review it from four
viewpoints:

    security-infra  secrets, privilege, supply chain, network,
                    container/host hardening
    senior          correctness, edge cases, error handling,
                    maintainability
    performance     hot paths, allocations, IO, concurrency, big-O
    api-ux          the consumer's view: clarity, breaking changes,
                    docs

Each actionable finding becomes a **local Forgejo issue** on the
mirror (labelled `gemini-review` + the persona) — it never touches
GitHub. The finding is also recorded in the dashboard issue store
(/var/lib/forcicd/issues.json) so it shows up with the one-click
auto-fix button.

Auth: GEMINI_API_KEY at /etc/forcicd/gemini-key (an AI Studio key).
Dedup: a local state file of reviewed "<repo>@<sha>" keys, plus a
per-key O_EXCL lock so a manual run can't race the timer.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from base64 import b64encode

FORGEJO_URL = os.environ.get("FORGEJO_URL", "http://localhost:3000")
FORGEJO_USER = os.environ.get("FORGEJO_ADMIN_USER", "ci")
ADMIN_PW_FILE = os.environ.get("ADMIN_PW_FILE", "/etc/forcicd/admin-password")
GEMINI_KEY_FILE = os.environ.get("GEMINI_KEY_FILE", "/etc/forcicd/gemini-key")
GEMINI_BIN = os.environ.get("GEMINI_BIN", "gemini")
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "")          # "" = gemini-cli default
STATE_FILE = os.environ.get("REVIEW_STATE_FILE", "/var/lib/forcicd/reviewed-commits")
ISSUE_STORE = os.environ.get("ISSUE_STORE", "/var/lib/forcicd/issues.json")
LABEL = os.environ.get("GEMINI_LABEL", "gemini-review")
DASH = os.environ.get("FORCICD_PUBLIC_URL", "http://forcicd.g8.lo:3000")

# Cap the diff we hand to Gemini (chars) so a huge commit doesn't
# blow the context / cost. Reviews the first DIFF_MAX_CHARS.
DIFF_MAX_CHARS = int(os.environ.get("REVIEW_DIFF_MAX_CHARS", "60000"))
# Don't review trivial/no-op diffs.
DIFF_MIN_CHARS = int(os.environ.get("REVIEW_DIFF_MIN_CHARS", "40"))
# Per-review safety cap on findings (post-parse) so one noisy commit
# can't open dozens of issues.
MAX_FINDINGS = int(os.environ.get("REVIEW_MAX_FINDINGS", "8"))
GEMINI_TIMEOUT = int(os.environ.get("GEMINI_TIMEOUT", "180"))

PERSONA_LABELS = {
    "security-infra": ("review/security-infra", "b60205"),
    "senior":         ("review/senior", "5319e7"),
    "performance":    ("review/performance", "fbca04"),
    "api-ux":         ("review/api-ux", "0e8a16"),
}
PERSONA_NAMES = set(PERSONA_LABELS)


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


PW = _read(ADMIN_PW_FILE)
GEMINI_KEY = _read(GEMINI_KEY_FILE)


def _auth():
    return "Basic " + b64encode(f"{FORGEJO_USER}:{PW}".encode()).decode()


def forgejo(path, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{FORGEJO_URL}{path}", data=data, method=method)
    if PW:
        req.add_header("Authorization", _auth())
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return 0, None


def forgejo_text(path):
    """GET a non-API (web) path — e.g. the commit .diff — as text."""
    req = urllib.request.Request(f"{FORGEJO_URL}{path}")
    if PW:
        req.add_header("Authorization", _auth())
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.read().decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError):
        return ""


# ---- mirrors + commits -------------------------------------------

def list_mirrors():
    """All Forgejo repos under the ci user → [(name, full_name)]."""
    out, page = [], 1
    while True:
        _, d = forgejo(f"/api/v1/repos/search?uid=0&limit=50&page={page}")
        items = (d or {}).get("data") or []
        if not items:
            break
        out += [(r["name"], r["full_name"]) for r in items]
        if len(items) < 50:
            break
        page += 1
    return out


def newest_commit(full):
    """(sha, branch, subject) of the newest commit, or None."""
    _, repo = forgejo(f"/api/v1/repos/{full}")
    branch = (repo or {}).get("default_branch") or "main"
    _, d = forgejo(f"/api/v1/repos/{full}/commits?limit=1&sha={branch}")
    if not d:
        return None
    c = d[0]
    subject = ((c.get("commit") or {}).get("message") or "").splitlines()[0]
    return c.get("sha"), branch, subject


def commit_diff(full, sha):
    txt = forgejo_text(f"/{full}/commit/{sha}.diff")
    if len(txt) > DIFF_MAX_CHARS:
        txt = txt[:DIFF_MAX_CHARS] + "\n\n[... diff truncated for review ...]\n"
    return txt


# ---- gemini ------------------------------------------------------

REVIEW_PROMPT = """\
You are a code reviewer. Review the following git commit diff from a \
project called "{repo}" (commit {sha7}: "{subject}").

Review it from FOUR independent viewpoints and report only \
*actionable* problems a maintainer would want fixed. Be specific and \
concrete; cite the file/area. Do NOT report style nits, praise, or \
"consider"-grade musings. If a viewpoint finds nothing actionable, \
emit nothing for it.

Viewpoints (use these exact persona keys):
- security-infra : secrets/credentials, privilege & isolation, \
supply chain, network exposure, container/host hardening, injection.
- senior : correctness bugs, unhandled errors, edge cases, \
race conditions, resource leaks, maintainability traps.
- performance : hot paths, needless allocations/IO, N+1, \
concurrency, algorithmic complexity.
- api-ux : the consumer's view — breaking changes, confusing \
interfaces/flags/config, missing or wrong docs.

Output STRICT JSON ONLY — a single JSON array, no prose, no \
markdown fences. Each element:
  {{"persona": "<one of: security-infra|senior|performance|api-ux>",
    "severity": "high|medium|low",
    "title": "<=80 char imperative summary",
    "body": "markdown: the problem, where, why it matters, and a \
concrete suggested fix"}}
Emit at most 2 findings per persona, highest-severity first. If \
there is nothing actionable at all, output exactly: []

=== DIFF ===
{diff}
"""


def run_gemini(repo, sha, subject, diff):
    """Run the Gemini CLI; return a list of finding dicts (possibly
    empty), or None on hard failure."""
    prompt = REVIEW_PROMPT.format(
        repo=repo, sha7=sha[:7], subject=subject, diff=diff)
    cmd = [GEMINI_BIN, "-p", prompt]
    if GEMINI_MODEL:
        cmd += ["--model", GEMINI_MODEL]
    env = dict(os.environ)
    env["GEMINI_API_KEY"] = GEMINI_KEY
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           env=env, timeout=GEMINI_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"  ! gemini invocation failed: {e}", file=sys.stderr)
        return None
    if p.returncode != 0:
        print(f"  ! gemini rc={p.returncode}: {p.stderr.strip()[:300]}",
              file=sys.stderr)
        return None
    return parse_findings(p.stdout)


def parse_findings(text):
    """Extract the JSON array from Gemini's output, tolerating
    markdown fences / surrounding prose."""
    if not text:
        return []
    # strip ```json ... ``` fences if present
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    blob = m.group(1) if m else text
    # narrow to the outermost [ ... ]
    s, e = blob.find("["), blob.rfind("]")
    if s < 0 or e < 0 or e <= s:
        return []
    try:
        data = json.loads(blob[s:e + 1])
    except json.JSONDecodeError:
        return []
    out = []
    for f in data if isinstance(data, list) else []:
        if not isinstance(f, dict):
            continue
        persona = str(f.get("persona", "")).strip().lower()
        title = str(f.get("title", "")).strip()
        body = str(f.get("body", "")).strip()
        if persona not in PERSONA_NAMES or not title or not body:
            continue
        sev = str(f.get("severity", "medium")).strip().lower()
        if sev not in ("high", "medium", "low"):
            sev = "medium"
        out.append({"persona": persona, "severity": sev,
                    "title": title[:80], "body": body})
    sev_rank = {"high": 0, "medium": 1, "low": 2}
    out.sort(key=lambda f: sev_rank[f["severity"]])
    return out[:MAX_FINDINGS]


# ---- forgejo labels + issues -------------------------------------

_label_cache = {}


def ensure_labels(full):
    """Return {name: id} for our labels on this repo, creating any
    that are missing. Cached per repo per process."""
    if full in _label_cache:
        return _label_cache[full]
    wanted = {LABEL: ("d73a4a", "Filed by the Gemini code reviewer")}
    for _, (name, color) in PERSONA_LABELS.items():
        wanted[name] = (color, "Gemini review viewpoint")
    _, existing = forgejo(f"/api/v1/repos/{full}/labels?limit=100")
    have = {l["name"]: l["id"] for l in (existing or [])}
    for name, (color, desc) in wanted.items():
        if name in have:
            continue
        _, created = forgejo(f"/api/v1/repos/{full}/labels", "POST",
                             {"name": name, "color": color, "description": desc})
        if created:
            have[name] = created["id"]
    _label_cache[full] = have
    return have


def existing_review_issue(full, title):
    """True if an open issue with this exact title already exists
    (re-install / state loss shouldn't dupe)."""
    from urllib.parse import quote
    _, d = forgejo(f"/api/v1/repos/{full}/issues?state=open&type=issues"
                   f"&labels={quote(LABEL)}&limit=50")
    return any((i.get("title") or "") == title for i in (d or []))


def record_issue(full, issue, labels):
    """Mirror a filed Forgejo issue into the dashboard store so it
    shows (with the auto-fix button) without polling."""
    key = f"{full}#{issue.get('number')}"
    try:
        try:
            store = json.load(open(ISSUE_STORE))
        except (FileNotFoundError, json.JSONDecodeError):
            store = {}
        store[key] = {
            "repo": full,
            "number": issue.get("number"),
            "title": issue.get("title"),
            "labels": labels,
            "state": "open",
            "html_url": f"{DASH}/{full}/issues/{issue.get('number')}",
            "updated_at": issue.get("created_at"),
            "kind": "gemini-review",
            "source": "forgejo",
        }
        tmp = ISSUE_STORE + ".tmp"
        json.dump(store, open(tmp, "w"))
        os.replace(tmp, ISSUE_STORE)
    except OSError:
        pass


SEV_EMOJI = {"high": "🔴", "medium": "🟠", "low": "🟡"}


def file_finding(full, sha, branch, f):
    labels = ensure_labels(full)
    persona_label = PERSONA_LABELS[f["persona"]][0]
    sha7 = sha[:7]
    title = f"[{f['persona']}] {f['title']}"
    if existing_review_issue(full, title):
        return f"  = {full} {title[:50]} (already open)"
    body = (
        f"{SEV_EMOJI.get(f['severity'], '')} **{f['severity'].upper()}** · "
        f"viewpoint `{f['persona']}`\n\n"
        f"{f['body']}\n\n"
        f"---\n"
        f"_Found by the Gemini code reviewer on "
        f"[`{sha7}`]({DASH}/{full}/commit/{sha}) (`{branch}`). "
        f"Local issue — not filed on GitHub. Click ▶ auto-fix in the "
        f"forcicd dashboard to have Claude fix it (scoped to this repo)._"
    )
    label_ids = [i for n, i in labels.items()
                 if n in (LABEL, persona_label)]
    code, created = forgejo(f"/api/v1/repos/{full}/issues", "POST",
                            {"title": title, "body": body, "labels": label_ids})
    if code in (200, 201) and created:
        record_issue(full, created, [LABEL, persona_label])
        return f"  + {full} #{created.get('number')} {title[:50]}"
    return f"  ! {full} {title[:50]} (create failed HTTP {code})"


# ---- state -------------------------------------------------------

def load_state():
    return set(filter(None, _read(STATE_FILE).splitlines()))


def append_state(key):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "a") as f:
        f.write(key + "\n")


def claim(key):
    """O_EXCL lock so a manual run can't race the timer for a sha."""
    lockdir = os.path.dirname(STATE_FILE)
    os.makedirs(lockdir, exist_ok=True)
    lock = os.path.join(lockdir, ".review-lock-" + key.replace("/", "_"))
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        return True
    except FileExistsError:
        return False


def review_repo(name, full, state):
    info = newest_commit(full)
    if not info:
        return None
    sha, branch, subject = info
    key = f"{name}@{sha}"
    if key in state or not claim(key):
        return None

    diff = commit_diff(full, sha)
    if len(diff.strip()) < DIFF_MIN_CHARS:
        append_state(key)
        return f"  · {name}@{sha[:7]} (empty/trivial diff, skipped)"

    findings = run_gemini(name, sha, subject, diff)
    if findings is None:
        # hard failure — do NOT record state, so we retry next tick
        return f"  ! {name}@{sha[:7]} (gemini failed, will retry)"

    append_state(key)
    if not findings:
        return f"  ✓ {name}@{sha[:7]} clean ({subject[:40]})"
    return "\n".join(file_finding(full, sha, branch, f) for f in findings)


def main():
    if not PW:
        print("no forgejo admin password; cannot poll", file=sys.stderr)
        sys.exit(2)
    if not GEMINI_KEY:
        print(f"no GEMINI_API_KEY at {GEMINI_KEY_FILE}; cannot review",
              file=sys.stderr)
        sys.exit(2)

    state = load_state()
    out = []
    for name, full in list_mirrors():
        r = review_repo(name, full, state)
        if r:
            out.append(r)
    if out:
        print("\n".join(out))


if __name__ == "__main__":
    main()
