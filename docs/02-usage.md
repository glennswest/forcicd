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
`--privileged --security-opt seccomp=unconfined --device /dev/fuse`
(see `forgejo/runner-config.yaml`) and join the `forcicd_default`
network (so they can reach `forgejo:3000` and
`forcicd-registry:5000` by name).

## Building bootc disk images (ISO / qcow2)

Building a **bootc** (bootable-container) image into a bootable
disk artifact — ISO, qcow2, raw, etc. — is fully supported on the
`bootc-c9s` runner. `bootc-image-builder` needs `--privileged`,
loop devices, and mount/partition access; forcicd's per-job
containers **already** run privileged (`--privileged --device
/dev/fuse --security-opt seccomp=unconfined`, see
`forgejo/runner-config.yaml`) and the job runs **as root** inside
that container, so the builder gets what it needs.

> **Do not** use `runs-on: self-hosted` and **do not** use `sudo`.
> Jobs run in a container, not on the VM host; the runner images
> have no `sudo` and run as root already. The `self-hosted` label
> is only for jobs that must touch the host's docker/qemu directly.

```yaml
  bootc-image:
    runs-on: bootc-c9s          # CentOS Stream 9 bootc + podman/buildah/skopeo + qemu-img
    steps:
      - uses: actions/checkout@v4

      # 1. Build the bootc container. podman is rootful here, so the
      #    image lands in /var/lib/containers/storage where the
      #    builder reads it via --local.
      - run: podman build -t localhost/myapp:ci -f Containerfile .

      # 2. bootc-image-builder → bootable disk. --privileged + the
      #    shared container storage are the whole trick.
      - run: |
          mkdir -p out
          podman run --rm --privileged \
            --security-opt seccomp=unconfined \
            -v "$PWD/out:/output" \
            -v /var/lib/containers/storage:/var/lib/containers/storage \
            quay.io/centos-bootc/bootc-image-builder:latest \
              build --type qcow2 --type iso --local localhost/myapp:ci
          find out -type f          # out/qcow2/disk.qcow2, out/bootiso/install.iso
```

Notes:

- `--local` reads the image from the job's own container storage
  (that's why step 2 bind-mounts `/var/lib/containers/storage`). No
  registry round-trip. To pull from a registry instead, push to
  `forcicd.g8.lo:5000` first and drop `--local`, passing the full
  ref.
- `--type` may be repeated (`iso`, `qcow2`, `raw`, `vmdk`, `ami`…).
  Output lands under `out/<type>/`.
- A rhel-coreos / rhel-bootc base works identically — just change
  the Containerfile `FROM` (plus entitlements if that base needs
  them, which is orthogonal to this recipe).
- Disk size / partitions / users come from an optional
  `config.toml`; mount it with `-v "$PWD/config.toml:/config.toml"`
  (bib auto-reads `/config.toml`).
- Publish the artifact as a release asset the same way as any other
  build output — see the release pattern below — or use
  `actions/upload-artifact@v3` (pin to `@v3`).

Copy-pasteable: [`../ci/bootc-image.example.yml`](../ci/bootc-image.example.yml).

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

## Issue-driven auto-fix (Claude)

The `/issues` tab lists every open issue across your repos;
`ci-failure` issues get two buttons:

- **▶ fixit** — autonomous. Spins a throwaway env, hands Claude the
  issue as the brief, lets it iterate with no turn limit, runs the
  build cycle. Claude writes a full root-cause + fix explanation to
  `FIX_WRITEUP.md`, which is posted to the issue. On a **green
  build** the issue gets a success comment and is **closed**
  (optionally a PR is opened); on red it stays open with the
  attempt attached.
- **⌨ interactive** — spins the same env with the repo + Claude +
  toolchain ready and leaves an attachable `screen` session; the
  attach command is posted to the issue. You drive it by hand;
  it tears down when you exit.

Both run via the host-side dispatcher (`forcicd-fixd.timer`) that
drains requests the dashboard drops. Install with
`scripts/install-fix-agent.sh`, then set the Claude hook in
`/etc/forcicd/fix.env`.

### Wiring your Claude client

The Claude client + subscription is yours to provide; forcicd
gives it a repo, a brief, and a build loop. Set in
`/etc/forcicd/fix.env`:

- `CLAUDE_CMD` — how to invoke it headlessly (gets the brief on
  stdin + at `/work/TASK.md`; must edit the tree in place and, for
  fixit, write `FIX_WRITEUP.md`).
- `FIX_BACKEND` — `docker` (throwaway container on the VM; mount
  Claude via `FIX_MOUNTS` or bake it into `FIX_IMAGE`) or `lxc`
  (throwaway CT on pve.g8.lo cloned from a template).
- For **lxc**: build the base template with
  `scripts/build-fix-lxc-template.sh`, install your Claude client +
  the history/indexing add-on into it (it persists the index across
  runs), `pct template` it, and set `FIX_LXC_TEMPLATE`.

Attach to any running worker: `ssh fedora@forcicd.g8.lo` then
`sudo screen -r <session>`.

## Deploying to an LXC/VM — the `cigate` deploy gate

Consumers that run as their own LXC/VM (e.g. qregistry) deploy
**into that host directly — never to the Proxmox host**. The CT/VM
is provisioned once out of band; CI only updates the running app,
and only through `cigate`: a busybox-style Rust binary (zero deps,
`panic=abort`, strict allowlist parsing) that exposes a fixed verb
set and nothing else.

`cigate` verbs: `deploy <ref>`, `rollback`, `restart`, `status`,
`logs [N]`, `ps`. It refuses unknown verbs, shell metacharacters,
and image refs from registries not in its policy. It never spawns a
shell — every action is an explicit argv to the container engine.

### Security model

- **Per-repo, self-only.** Each consumer gets its **own** ed25519
  key and a **repo-scoped** `DEPLOY_KEY` secret (never org-wide). A
  repo's key only works on **its own** target host and can only run
  `cigate` there. One repo cannot deploy another.
- The key is authorized with `command="/usr/local/bin/cigate"` +
  `from="<runner IP>"` + no pty/forwarding — it has no shell.
- Per-target policy (`/etc/forcicd-deploy/gate.conf`) bounds the
  container name, allowed registries, and run args.
- **The hypervisor is never touched.** No key to `pve.g8.lo`.

### Set it up (one-time, by the forcicd owner)

```bash
# build cigate (in a runner container), install it + a restricted
# key on the target, register the repo-scoped secret:
./scripts/install-app-deploy.sh qregistry qregistry.g10.lo root
# then tune /etc/forcicd-deploy/gate.conf on the target (container
# name, registries, run args).
```

Add a deploy job from `deploy/deploy.example.yml` to the repo's
workflow. It `needs: [test]` and only runs on `main`, so a red
build never deploys.

## Runner action compatibility

The Forgejo Actions runner is GHES-class, so a few GitHub actions
need pinning in mirrored repos' workflows:

- **`actions/upload-artifact` / `download-artifact`: pin `@v3`.**
  `@v4+` errors with *“@actions/artifact v2.0.0+ … not currently
  supported on GHES.”* The build itself is fine; only the artifact
  step fails.
- **`node24`-based actions** (e.g. `Swatinem/rust-cache@v2.8+`):
  pin to the last `node20` release (`@v2.7.7`) until the runner
  ships node24. (forgejo/runner:7 is node20.)

## Roadmap notes

- **GitLab repos** — the overview is GitHub-only today. The
  dashboard's `gh_*` helpers are isolated enough to add a parallel
  `gl_*` set and merge rows; tracked for a later cut.
- **Per-project tabs** — overview first; a drill-down per repo
  (runs, PRs, issues, deploy history) comes after.
