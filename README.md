# forcicd

Local CI/CD for fastetcd (and friends) running on `pve.g8.lo`.
Forgejo + Forgejo Actions, native GitHub-Actions YAML compatible
so `.github/workflows/ci.yml` from
[fastetcd](https://github.com/glennswest/fastetcd) runs unmodified.

## Why this exists

The GitHub-hosted CI loop is too slow for the inner iteration we
want during fastetcd development:

```
laptop push → GitHub Actions queue (~1m) → cold runner →
container build → ghcr push → kubetest VM pull → restart
```

End-to-end ~5–10 minutes per change. A local runner sitting on
the same LAN, talking to a local registry (`fastregistry.g10.lo`)
and rolling the kubetest etcd pod as the last step, drops that
to ~1–2 minutes — **push to deploy** on the LAN.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ forcicd.g8.lo  (192.168.8.154, VMID 115, Fedora 43)              │
│   - Forgejo server (port 3000 HTTP — GUI for code, workflows,    │
│     runners, settings, mirror)                                   │
│   - act_runner (Forgejo's GitHub-Actions-compatible runner) —    │
│     8 toolchain image variants registered as labels              │
│   - CD watcher (systemd timer, polls every 30s) — when a new     │
│     green build lands on main, fetches the artifact, builds the  │
│     scratch container, pushes to fastregistry, rolls kubetest    │
│   - Ops dashboard (port 80, also 8090) — multi-project + CD     │
└──────────────────────────────────────────────────────────────────┘
            │                                       ▲
            │ image push                            │ git pull mirror
            ▼                                       │
   fastregistry.g10.lo                  github.com/glennswest/fastetcd
   (mkube; already exists)
```

All services run as a Docker Compose stack on a single VM. Splittable
later if scale demands it.

## What this is NOT

- Not a replacement for GitHub Actions — that keeps running too,
  so external contributors / public test results still flow.
- Not a generic multi-tenant CI service — scoped to fastetcd and
  siblings. The pattern generalizes; the initial setup is scoped.

## Runner labels (35+)

The runner exposes every label a workflow might use, mapped to one
of 8 prebuilt toolchain images. All images carry: rust stable
(+ aarch64-gnu / aarch64-musl / x86_64-musl targets), go 1.22 with
cross-compile, C (gcc + gcc-aarch64-linux-gnu + headers), kernel
build prereqs (make/bc/flex/bison/libssl/libelf/dwarves/cpio/kmod),
docker CLI + buildx, qemu-user-static for multi-arch builds.

| Label(s) | Image | Notes |
|---|---|---|
| `ubuntu-latest`, `ubuntu-22.04`, `ubuntu-24.04` | `forcicd-runner-ubuntu22` | GitHub-parity default |
| `rhel-8`, `ubi-8`, `ocp-4.7` … `ocp-4.12` | `forcicd-runner-ubi8` | RHCOS 4.7→4.12 era |
| `rhel-9`, `ubi-9`, `ocp-4.13` … `ocp-4.18` | `forcicd-runner-ubi9` | RHCOS 4.13→4.18 era. bootc CLI present. |
| `rhel-10`, `ubi-10`, `ocp-4.19`, `ocp-5.0` | `forcicd-runner-ubi10` | RHCOS 4.19 / proposed 5.0. bootc CLI present. |
| `alpine`, `alpine-latest` | `forcicd-runner-alpine` | musl target verification |
| `debian`, `debian-12`, `bookworm` | `forcicd-runner-debian12` | |
| `debian-11`, `bullseye` | `forcicd-runner-debian11` | oldstable |
| `bootc`, `bootc-c9s`, `bootc-centos9` | `forcicd-runner-bootc` | CentOS Stream 9 bootc + podman/buildah/skopeo |
| `self-hosted` | host | escape hatch for jobs that need direct docker/qemu |

UBI images optionally register with `subscription-manager` for full
RHEL repos when `RHEL_ORG_ID` + `RHEL_ACTIVATION_KEY` are passed as
build args.

### Building bootc disk images (ISO / qcow2)

Per-job containers already run `--privileged --device /dev/fuse
--security-opt seccomp=unconfined` (jobs run as root inside them),
so `bootc-image-builder` works on the `bootc-c9s` runner with **no**
`self-hosted` / `sudo` — `podman build` the bootc image, then
`podman run … bootc-image-builder build --type qcow2 --local …`.
Copy-pasteable recipe: [`ci/bootc-image.example.yml`](ci/bootc-image.example.yml);
full walkthrough in [docs/02-usage.md](docs/02-usage.md#building-bootc-disk-images-iso--qcow2).

## GUIs

| URL | What it shows |
|---|---|
| `http://forcicd.g8.lo:3000` | **Forgejo** — code, workflow runs, runners, mirror settings, admin |
| `http://forcicd.g8.lo` | **forcicd ops dashboard** — multi-project overview + local CI (also on `:8090`) |

The CLI equivalents are `make status` (point-in-time) and
`make verify` (nonzero on first failure).

## Quick start

```
cp proxmox.env.sample proxmox.env
make up         # provision VM + install stack + bootstrap
make images     # build all 8 runner toolchain images (slow first time)
./scripts/install-cd.sh   # opt-in: install the CD watcher on the VM
make verify     # end-to-end smoke
```

Open `http://forcicd.g8.lo:3000` and you should see the `ci/fastetcd`
mirror. Push a commit to fastetcd `main` upstream — the mirror picks
it up within ~1 minute, the runner picks up the job, and (with CD
enabled) within ~5 minutes the new image is on `fastregistry.g10.lo`
and the kubetest pod has been rolled.

## VM specs

12 vCPU, 32 GiB RAM, 64 GiB disk, Fedora 43 cloud. Bumped from 4/8
because image builds + parallel CI jobs both want headroom.

## License

Apache 2.0.
