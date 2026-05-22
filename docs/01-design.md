# 01 — Design

## Goal

Cut the CI feedback loop from ~5–10 minutes (GitHub-hosted) to
~1–2 minutes (LAN-local), with **zero workflow drift**: the same
`.github/workflows/ci.yml` file that runs on `github.com` runs
here too, against the same `actions/*` ecosystem.

## Why Forgejo Actions specifically

| Option | YAML compat | Effort | Notes |
|---|---|---|---|
| **Forgejo Actions** ✓ | Native GitHub-Actions | Low | act_runner = wrapper around [`nektos/act`]; same YAML semantics |
| Gitea Actions | Native GitHub-Actions | Low | Same family. Forgejo is the open-governance fork; either would work. |
| Drone CI | Custom `.drone.yml` | Medium | Requires translating the workflow. Mature, but defeats the "zero drift" goal. |
| Jenkins | Custom `Jenkinsfile` | High | Too heavy for this scope. |
| Self-hosted GitHub runner | Native | Low *but* needs a public GitHub repo; CI traffic still hits GitHub for queueing | Doesn't actually reduce GitHub-trip latency. |

Forgejo Actions wins because it removes GitHub from the critical
path entirely while keeping the YAML and the ecosystem.

## Topology

```
                                    ┌────────────────────────────────────────┐
                                    │ forcicd.g8.lo (192.168.8.154, VMID 114)│
   github.com/glennswest/fastetcd ──┤  ▲                                      │
        (canonical, public)         │  │ pull-mirror every 60s                │
                                    │  ▼                                      │
                                    │  Forgejo server (port 3000)             │
                                    │   ├─ web UI                             │
                                    │   ├─ Git over SSH (port 22)             │
                                    │   └─ Container registry                 │
                                    │      (image storage)                    │
                                    │                                          │
                                    │  act_runner (per-job ephemeral docker)  │
                                    │   ├─ pulls workflow YAML                │
                                    │   ├─ runs jobs in docker containers     │
                                    │   └─ pushes images to fastregistry      │
                                    └────────────────────────────────────────┘
                                                  │
                                                  │ podman push
                                                  ▼
                                       fastregistry.g10.lo
                                       (mkube-owned, already exists)
```

## VM specs (matches kubetest pattern)

- VMID **114**, hostname **forcicd.g8.lo**, IP **192.168.8.154/24**
- Fedora 43 cloud image (already on pve, `/var/lib/vz/template/iso/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2`)
- 4 vCPU / 8 GiB RAM / 64 GiB disk (bigger than kubetest — we host the runner workspace + image cache here)
- vmbr0, static IP via cicustom
- Same SSH key as kubetest

## Software stack

| Layer | Tool | Why |
|---|---|---|
| OS | Fedora 43 cloud | Same base as fastetcd_uptest; cloud-init we already trust |
| Container runtime | Docker (not Podman) | act_runner currently has best support for `dockerd`; Podman support exists but rougher |
| Forgejo | `codeberg.org/forgejo/forgejo:v9` (latest stable) | Compose service `forgejo` |
| Runner | `code.forgejo.org/forgejo/runner:6` | Compose service `runner`, talks to `forgejo` over docker network |
| Registry | reuse `fastregistry.g10.lo` (192.168.10.50, mkube) | No new infra; CI images push here |

All on a single VM. Docker Compose file at `forgejo/compose.yml`.

## Bootstrap flow

`scripts/bootstrap.sh` is idempotent:

1. **Admin user**: `forgejo admin user create --admin --username=ci`
   if not already present. Password written to
   `/etc/fastetcd-ci/admin-password` (root-readable only).
2. **Runner registration**: `forgejo forgejo-cli actions
   generate-runner-token` → POST to `runner` container env var →
   restart runner. Idempotent: if runner already registered,
   skip.
3. **Mirror repo**: `curl -X POST` against Forgejo's API to
   create a "mirrored" repository pointing at
   `https://github.com/glennswest/fastetcd.git`. Mirror interval
   set to 1 minute.
4. **Verify**: poll Forgejo's API until the mirrored repo's
   default branch matches `HEAD@upstream`. Print the URL.

## What success looks like

After bootstrap finishes, the loop is:

```
$ # in fastetcd repo
$ git push origin main

$ # within ~60s, Forgejo's pull-mirror catches up.
$ # within ~30s after that, runner picks up the workflow.
$ # Cargo test + image build + push to fastregistry within ~4 min.

$ # Total: ~5 min, all on the LAN.
```

## Limits / known gaps

- **One runner.** Concurrency capped at one job at a time. Easy
  to add more containers later; the bootleneck this turn is
  iteration speed, not throughput.
- **`actions/checkout@v4`** uses GitHub's hosted action by
  default. Forgejo Actions mirrors these on demand from
  github.com, so the first run after a fresh install does an
  extra fetch. Cached after that.
- **`dtolnay/rust-toolchain@stable`** and
  `Swatinem/rust-cache@v2` similarly fetched from GitHub on
  first use. Same caching applies.
- **macOS jobs**: GitHub Actions provides hosted macOS runners.
  We can't easily reproduce that on pve — Forgejo Actions
  supports it via a Mac builder in principle, but for now we
  skip the `macos-latest` matrix entries on the local runner
  (they still run on GitHub).
- **No secrets manager.** Anything sensitive lives on the VM
  filesystem under `/etc/fastetcd-ci/`. Fine for the scope; if
  we ever want OIDC-to-cloud, we revisit.

## Non-goals

- A multi-tenant CI service.
- Replacing the public GitHub CI. We keep it; this is a faster
  shadow that runs on every push.
