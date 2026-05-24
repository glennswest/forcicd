# Changelog

## [Unreleased]

### 2026-05-24
- **feat:** Multi-project overview dashboard (`:8090/`) across all
  owned GitHub repos — CI status, open PRs/issues, last-push age,
  sortable + filterable. forcicd-internal view moved to `/local`.
- **feat:** `scripts/bulk-mirror.sh` — mirror many GitHub repos
  into Forgejo at once (`--active [DAYS]` discovers them via the
  VM's GitHub token).
- **feat:** `scripts/set-gh-secret.sh` — register the GitHub push
  token as a Forgejo Actions secret (`GH_PUSH_TOKEN`) so workflow
  jobs can push commits / cut releases back to GitHub.
- **feat:** GitHub token stored on the VM at
  `/etc/forcicd/github-token` (0600 root), mounted read-only into
  the dashboard.
- **docs:** `docs/02-usage.md` — dashboards, adding projects,
  CI-push-back / release pattern, CD, roadmap.
- **fix:** CD watcher uses `/actions/tasks` (not `/runs`, which
  404s in Forgejo 9) and gates on "all `test (ubuntu-*)` green for
  a SHA" instead of the upstream build job (which never runs here
  because its `needs: [test]` waits on always-cancelled macos
  matrix entries). CD watcher enabled via `scripts/install-cd.sh`.
- **fix:** Local CI verified end-to-end — runner upgraded to
  forgejo/runner:7, per-job containers join `forcicd_default`
  (resolve `forgejo:3000`) and get `--security-opt
  seccomp=unconfined` (io_uring). All 3 ubuntu test-matrix jobs
  pass green for fastetcd.

## [v0.1.0] — 2026-05-23

First operational cut. Goes from "scaffolding" → "Forgejo + runner
+ dashboard + local registry up on `forcicd.g8.lo`, mirror in
sync, 5/9 runner toolchain images pushed". Per pre-1.0 semver
this MINOR bump may include breaking changes; the public API is
not yet stable.

### Added
- **Forgejo + act_runner + ops dashboard + local registry stack**
  on `forcicd.g8.lo` (VMID 115, Fedora 43, 12 vCPU / 32 GiB /
  512 GiB), brought up via `make up`.
- **Ops dashboard** at `http://forcicd.g8.lo:8090` — VM/container
  health, runner labels, CD drift (last-deployed vs latest-green
  SHA). Forgejo at `:3000` remains the GUI for code/workflows/
  runners/settings.
- **CD half** (opt-in via `scripts/install-cd.sh`) — `cd/deploy.sh`
  builds a scratch container from a Forgejo workflow artifact +
  pushes to the local registry + optionally rolls a kubetest pod;
  `cd/watcher.sh` polls Forgejo every 30s via systemd timer for
  new green builds on `main`.
- **9 runner toolchain image variants** declared:
  `ubuntu22`, `ubi8`, `ubi9`, `ubi10`, `alpine`, `debian11`,
  `debian12`, `bootc`, `fedora43`. 5 pushed at release time
  (ubuntu22, alpine, debian11, debian12, ubi9); the other 4
  build via `make image-X`.
- **35+ runner labels** so workflows can target any major distro
  by name: `ubuntu-{latest,22.04,24.04}`, `rhel-{8,9,10}`,
  `ubi-{8,9,10}`, `ocp-4.7` → `ocp-5.0` (OCP→RHCOS mapping),
  `alpine`, `debian` + `bookworm`/`bullseye`, `bootc-c9s`,
  `fedora`, `self-hosted`.
- **Local Docker registry** container on `:5000` (mkube's
  `fastregistry.g10.lo` returns 500 on push — broken
  `/data/registry/uploads` dir; running our own removes the
  dependency).
- **Top-level Makefile** + `scripts/status.sh` + `scripts/verify.sh`.
- **`scripts/build-runner-image.sh`** — build one or all variants
  on the VM, push to the local registry.

### Fixed
- VMID 114 collided with an LXC `registry.gw.lo` on `pve.g8.lo`
  — moved to VMID 115.
- Forgejo's first-run install wizard intercepted every API call
  until completion — set `INSTALL_LOCK=true` + sqlite DB defaults
  so `bootstrap.sh` drives setup over the API.
- The `forgejo:9` image already binds OpenSSH on container :22,
  collided with Forgejo's builtin SSH — disabled the builtin;
  git over HTTP works on the LAN.
- The runner container's default CMD is bare `forgejo-runner`
  (just prints --help) — set `command: ["/bin/forgejo-runner",
  "daemon"]`.
- The runner crashes-loops without `/data/.runner`, so
  `docker exec` to register doesn't work first time — register
  via a one-shot `docker run --rm` against the shared volume.
- SELinux on Fedora 43 blocked the runner from
  `/var/run/docker.sock` even with file perms — added
  `security_opt: label=disable`.
- Dashboard was sending an Authorization header with an empty
  password (file existed but was empty before bootstrap) — only
  send auth header when password is non-empty.
- VM disk filled to 100% during the first image-build batch —
  grew to 512 GB, set `max-concurrent-uploads=1` in docker
  daemon.json (registry was racing on parallel layer uploads
  → `blob upload invalid`).
- UBI dockerfiles assumed packages that aren't in UBI without
  RHEL subscription (`flex`, `bison`, `dwarves`,
  `protobuf-compiler`, `gcc-aarch64-linux-gnu`, `kernel-devel`,
  `qemu-user-static`, `bootc`, `elfutils-libelf-devel`) — those
  live in full RHEL CRB only, dropped from UBI variants with a
  comment pointing to ubuntu22/debian12/fedora43/bootc when
  needed.

### Changed
- VM specs: 4 vCPU / 8 GiB → 12 vCPU / 32 GiB / 512 GiB.
- `LOCAL_REGISTRY` default: `fastregistry.g10.lo` →
  `forcicd.g8.lo:5000`.

## [v0.0.1] — 2026-05-21
- Initial scaffolding. README, CLAUDE.md, design notes, scripts
  skeleton. No runnable infrastructure yet.
