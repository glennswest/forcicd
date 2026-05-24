# 02 — Usage

How to operate forcicd day to day: the dashboard, adding projects,
and letting CI jobs push commits / cut releases back to GitHub.

## Dashboards

| URL | View |
|---|---|
| `http://forcicd.g8.lo/` | **Overview** — every repo you own, pushed in the last 30 days, in one table: latest CI status, open PRs, open issues, last-push age. Header has roll-up counts. Sort by clicking a column; filter with the search box. (Also on `:8090`.) |
| `http://forcicd.g8.lo/local` | **Local CI** — forcicd internals: VM/container health, runner labels, mirror sync, CD drift. |
| `http://forcicd.g8.lo:3000/` | **Forgejo** — the actual git server: code, workflow runs + logs, runner admin, repo settings, secrets. |

### Tuning the overview

Environment variables on the `dashboard` service (in
`forgejo/compose.yml`):

- `GH_ACTIVE_DAYS` (default `30`) — recency window for "active".
- `GH_AFFILIATION` (default `owner`) — set to
  `owner,collaborator,organization_member` to include org repos
  (warning: this can be hundreds).
- `GH_REPOS_PAGES` (default `5`) — pages of 100 repos to scan.
- `GH_CACHE_SECS` (default `60`) — GitHub response cache TTL.

The overview needs a GitHub token at `/etc/forcicd/github-token`
(0600, root) — see "GitHub token" below.

## Adding a project to local CI

forcicd runs a project's existing `.github/workflows/*.yml`
unmodified by **mirroring** the GitHub repo into Forgejo. To add a
repo:

```bash
# One-off, mirrors a single repo (same API bootstrap.sh uses):
PW=$(cat build/admin-password)
curl -s -u "ci:${PW}" -X POST \
  http://forcicd.g8.lo:3000/api/v1/repos/migrate \
  -H 'Content-Type: application/json' \
  -d '{
    "repo_name": "myproject",
    "clone_addr": "https://github.com/glennswest/myproject.git",
    "mirror": true,
    "mirror_interval": "1m0s",
    "repo_owner": "ci",
    "service": "github"
  }'
```

Or use `scripts/bulk-mirror.sh` to mirror many at once (see
`--help`). After mirroring, the runner picks up the workflow on
the next push to the mirrored branch (force a sync immediately
with `POST /api/v1/repos/ci/<name>/mirror-sync`).

### Targeting a runner image

Workflows pick a runner image via `runs-on:`. forcicd maps these
labels (see README for the full table):

- `ubuntu-latest` / `ubuntu-22.04` → ubuntu toolchain image
- `rhel-9` / `ubi-9` / `ocp-4.13`…`ocp-4.18` → RHEL 9 (UBI 9)
- `fedora` / `fedora-43`, `alpine`, `debian-12`, `bootc-c9s`, …

A job that needs io_uring, KVM, or other privileged kernel
features runs fine — per-job containers get
`--security-opt seccomp=unconfined` and join the
`forcicd_default` network (so they can reach `forgejo:3000` and
`forcicd-registry:5000` by name).

## Letting CI jobs push commits / cut releases

Forgejo Actions jobs run in ephemeral containers with **no git
credentials** by default. To push back to GitHub (commit a version
bump, push a tag, create a release) a job needs a token.

### 1. Store the token as a Forgejo secret

The token already lives on the VM at `/etc/forcicd/github-token`
(it needs the `repo` scope; the bootstrap token has it). Register
it as a Forgejo **secret** so workflows can read it as
`${{ secrets.GH_PUSH_TOKEN }}`:

```bash
PW=$(cat build/admin-password)
TOKEN=$(ssh fedora@forcicd.g8.lo 'sudo cat /etc/forcicd/github-token')

# Org/user-level secret (available to all repos owned by `ci`):
curl -s -u "ci:${PW}" -X PUT \
  "http://forcicd.g8.lo:3000/api/v1/user/actions/secrets/GH_PUSH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"data\": \"${TOKEN}\"}"

# …or per-repo:
curl -s -u "ci:${PW}" -X PUT \
  "http://forcicd.g8.lo:3000/api/v1/repos/ci/<name>/actions/secrets/GH_PUSH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"data\": \"${TOKEN}\"}"
```

`scripts/set-gh-secret.sh` wraps this.

### 2. Use it from a workflow

Pushing a commit / tag:

```yaml
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: bump + tag
        env:
          GH_PUSH_TOKEN: ${{ secrets.GH_PUSH_TOKEN }}
        run: |
          git config user.name  "forcicd"
          git config user.email "ci@g8.lo"
          # … edit files, bump version …
          git commit -am "chore(release): v${VERSION}"
          git tag "v${VERSION}"
          git push "https://x-access-token:${GH_PUSH_TOKEN}@github.com/glennswest/<name>.git" HEAD:main --tags
```

Creating a GitHub release (the `gh` CLI is preinstalled in the
runner images):

```yaml
      - name: gh release
        env:
          GH_TOKEN: ${{ secrets.GH_PUSH_TOKEN }}
        run: gh release create "v${VERSION}" --notes "Automated by forcicd"
```

### Secondary "release" jobs

Keep test and release concerns separate: gate the release job on
the test jobs and a tag/branch condition so it only fires when you
mean it.

```yaml
  release:
    needs: [test]
    if: startsWith(github.ref, 'refs/tags/v')
```

> **Note** — because forcicd has no macOS runner, jobs that
> `needs:` a `macos-latest` matrix entry will never start (the
> macOS entry *cancels*, and `needs` treats a cancelled dep as
> unmet). Either give the release job an explicit
> `if: ${{ !cancelled() }}`-style guard, or don't depend on
> macOS-only jobs. forcicd's CD watcher sidesteps this by gating
> on "all `test (ubuntu-*)` green" rather than on the build job.

## Failures → issues, and the release gate

Two guarantees once `scripts/install-ci-issues.sh` and
`scripts/install-cd.sh` are in place:

1. **A failed local build files a GitHub issue.** Every 60s,
   `ci/issue-on-failure.sh` checks the newest commit of each
   mirrored repo; if any job failed and there's no open
   `ci-failure` issue for that commit, it opens one on
   `github.com/<owner>/<repo>` listing the failed jobs + a link to
   the forcicd run log. Deduped, so you get one issue per failing
   commit, not per poll.

2. **A red build never releases.** The CD watcher only acts on a
   commit whose gating jobs (default: every `test (ubuntu-*)`
   matrix entry) are *all* success with *zero* failures. A repo
   with a failing test has "no deployable green SHA" and is
   skipped — no image push, no pod roll, no tag. For release jobs
   that live inside a workflow, gate them the same way:
   `needs: [test]` (Forgejo honours it — a failed dependency means
   the release job never starts).

## CD: push-to-deploy

`scripts/install-cd.sh` installs a systemd timer that, every 30s,
checks for a new fully-green commit on `main` and runs
`cd/deploy.sh` (build container from the workflow artifact → push
to `forcicd.g8.lo:5000` → optionally roll a kubetest pod). Drop a
kubeconfig at `/etc/forcicd/kubetest.kubeconfig` on the VM to
enable the cluster-roll step; without it the watcher still builds
and pushes the image.

State (last-deployed SHA) lives at
`/var/lib/forcicd/last-deployed`; the dashboard's Local CI tab
shows drift between latest-green and last-deployed.

## Roadmap notes

- **GitLab repos** — the overview is GitHub-only today. The
  dashboard's `gh_*` helpers are isolated enough to add a parallel
  `gl_*` set and merge rows; tracked for a later cut.
- **Per-project tabs** — overview first; a drill-down per repo
  (runs, PRs, issues, deploy history) comes after.
