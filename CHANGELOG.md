# Changelog

## [Unreleased]

### 2026-05-23
- **feat:** Ops dashboard at `http://forcicd.g8.lo:8090` — VM/container
  health, runner labels, CD drift (last-deployed vs latest-green-SHA).
  Forgejo (port 3000) remains the GUI for code/workflows/runners/settings;
  this complements it with forcicd-specific ops view. Lives as a 3rd
  container in the compose stack.
- **feat:** CD half — `cd/deploy.sh` (artifact → container → push +
  optional kubectl roll), `cd/watcher.sh` (poll Forgejo for new green
  builds), systemd timer firing every 30s. `scripts/install-cd.sh`
  installs it on the VM. Without `kubetest.kubeconfig` the watcher
  still builds + pushes; only the cluster roll is skipped.
- **feat:** 8 runner image variants, all with the same toolchain
  (rust + aarch64-gnu/musl + x86_64-musl, go 1.22, C + aarch64 cross,
  kernel-build prereqs, docker CLI + buildx, qemu-user-static):
  - `ubuntu22`  — Ubuntu 22.04 (default for `ubuntu-*` labels)
  - `ubi8/9/10` — RHEL family (OCP 4.7 → 5.0 coverage)
  - `alpine`    — musl target verification
  - `debian11/12` — bullseye + bookworm
  - `bootc`     — CentOS Stream 9 bootc (bootable-container builds,
    bootc CLI + podman/buildah/skopeo)
  UBI images optionally subscription-manager register when
  `RHEL_ORG_ID` + `RHEL_ACTIVATION_KEY` are passed as build args.
- **feat:** `bootc` CLI added to UBI 9/10 too, so jobs running on
  those can build bootc images without switching variants.
- **feat:** Runner registered with ~35 labels — `ubuntu-*`,
  `rhel-{8,9,10}`, `ubi-{8,9,10}`, `ocp-4.7` through `ocp-5.0`,
  `alpine`, `debian` + `bookworm`/`bullseye`, `bootc*`, `self-hosted`.
- **feat:** Top-level `Makefile` — `make up | images | image-X |
  status | verify | logs | ssh | destroy | clean`.
- **feat:** `scripts/status.sh` (colour-coded health snapshot) and
  `scripts/verify.sh` (end-to-end smoke; nonzero on first failure).
- **chore:** VM bumped from 4 vCPU / 8 GiB → 12 vCPU / 32 GiB.
  pve.g8.lo has the headroom (188 GiB host RAM); image builds are
  apt/dnf + rustup heavy and benefit from more cores.
- **chore:** Move VMID from 114 → 115 (114 was held by an LXC
  `registry.gw.lo`).
- **fix:** `FORGEJO__security__INSTALL_LOCK=true` + sqlite DB defaults
  to skip the first-run install wizard — `bootstrap.sh` drives setup
  over the API.
- **fix:** Disable Forgejo's builtin SSH server (the `forgejo:9` image
  already binds OpenSSH on container :22). Git over HTTP on the LAN.
- **fix:** Runner registration via one-shot `docker run` against the
  shared volume — the long-lived container crash-loops without
  `/data/.runner`, so `docker exec` doesn't work first time.
- **fix:** Runner compose CMD set to `forgejo-runner daemon`; image's
  default CMD is bare `forgejo-runner` (just prints --help).
- **fix:** `security_opt: label=disable` on the runner so SELinux lets
  it talk to `/var/run/docker.sock` on Fedora 43.
- **fix:** Dashboard only sends auth header when admin-password is
  non-empty (was sending bad auth and getting 401 on `/version`).
- **feat:** Provisioned `forcicd.g8.lo` (VMID 115, 192.168.8.154);
  Forgejo + act_runner + dashboard stack up; mirror of
  `github.com/glennswest/fastetcd` syncing every 1m.

### 2026-05-21
- **chore:** Initial scaffolding. README, CLAUDE.md, design notes,
  scripts skeleton. No runnable infrastructure yet.
