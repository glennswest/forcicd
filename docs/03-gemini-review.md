# Gemini review → local issues → Claude auto-fix

forcicd runs two loops over every push:

- the **build loop** — Forgejo Actions runs the workflow; a red
  build files a `ci-failure` GitHub issue (`issue-on-failure.py`).
- the **quality loop** — Gemini reviews the pushed code and files
  **local Forgejo issues**; Claude fixes them on the VM fix-worker.

This doc covers the quality loop.

## Flow

```
push to a mirror ──► gemini-review.py (timer, 60s)
                       │  newest un-reviewed commit per repo
                       │  fetch its .diff from Forgejo
                       ▼
                     Gemini CLI  ── reviews from 4 viewpoints ──►
                       security-infra · senior · performance · api-ux
                       │  STRICT JSON findings
                       ▼
                     LOCAL Forgejo issue per finding
                       label: gemini-review + review/<persona>
                       (also recorded in the dashboard issue store)
                       ▼
                     ▶ auto-fix  ──►  ci/fix-worker.sh on the VM
                       Claude (danger mode), scoped to that one repo,
                       detailed commit + explanation back on the issue
```

Polling the **local** Forgejo every 60s is intentional — it's cheap
and exactly how `issue-on-failure.py` already works. We still never
poll GitHub.

## Install

```bash
# 1. Get an AI Studio key: https://aistudio.google.com/apikey
# 2. Provide it (never committed — build/ and *.key are gitignored):
GEMINI_API_KEY=AIza... ./scripts/install-gemini-review.sh
#    ...or drop it in build/gemini-key and run without the env var.
```

The installer puts the key at `/etc/forcicd/gemini-key` (0600),
installs the Gemini CLI (`@google/gemini-cli` + node) if missing,
deploys `gemini-review.py`, and enables `forcicd-gemini.timer`.

Run a review pass immediately:

```bash
ssh fedora@forcicd.g8.lo 'sudo systemctl start forcicd-gemini.service'
journalctl -u forcicd-gemini.service -n 50 --no-pager
```

## The four viewpoints

| persona | label | looks for |
|---|---|---|
| `security-infra` | `review/security-infra` | secrets, privilege & isolation, supply chain, network exposure, container/host hardening, injection |
| `senior` | `review/senior` | correctness, unhandled errors, edge cases, races, leaks, maintainability |
| `performance` | `review/performance` | hot paths, allocations/IO, N+1, concurrency, complexity |
| `api-ux` | `review/api-ux` | breaking changes, confusing interfaces/flags/config, missing/wrong docs |

Each finding is one Forgejo issue titled `[<persona>] <summary>`,
body = severity + the problem + a concrete suggested fix.

## Tuning (env on `forcicd-gemini.service`)

| var | default | meaning |
|---|---|---|
| `GEMINI_MODEL` | gemini-cli default | model id, e.g. `gemini-2.5-flash` |
| `REVIEW_DIFF_MAX_CHARS` | 60000 | cap the diff handed to Gemini |
| `REVIEW_MAX_FINDINGS` | 8 | issues opened per commit (≤2/persona) |
| `GEMINI_TIMEOUT` | 180 | seconds per `gemini` invocation |
| `GEMINI_LABEL` | gemini-review | umbrella label |

State (reviewed `<repo>@<sha>` keys) lives at
`/var/lib/forcicd/reviewed-commits`; delete it to re-review.

## Fixing the findings

The findings are ordinary local issues, so the dashboard's ▶
auto-fix button drives the **same** `ci/fix-worker.sh` used for
`ci-failure` issues — Claude in danger mode, in a throwaway env, a
fresh clone of **only that repo**, with a detailed commit and the
fix explanation posted back to the issue. Wiring (CLAUDE_CMD etc.)
is in [02-usage.md](02-usage.md) and `ci/fix.env.sample`.
