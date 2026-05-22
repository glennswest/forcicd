# forcicd

Local CI for fastetcd (and friends) running on `pve.g8.lo`.
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
should drop that to ~1–2 minutes.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ forcicd.g8.lo  (192.168.8.154, VMID 114, Fedora 43)              │
│   - Forgejo server (port 3000 HTTP, 22 SSH)                      │
│       │ - Mirrors github.com/glennswest/fastetcd                 │
│       │ - Hosts a local container registry                       │
│       │                                                           │
│   - act_runner (Forgejo's GitHub-Actions-compatible runner)      │
│       runs every job inside a fresh container, same as upstream  │
└──────────────────────────────────────────────────────────────────┘
            │                                       ▲
            │ image push                            │ git pull mirror
            ▼                                       │
   fastregistry.g10.lo                  github.com/glennswest/fastetcd
   (already exists; mkube)
```

Both Forgejo and the runner live on the same VM as a Docker
Compose stack. Simpler than two VMs; we can split later if scale
demands.

## What this is NOT

- Not a replacement for GitHub Actions — we keep that working too
  so external contributors / public test results still flow.
- Not a generic CI server for unrelated projects — just fastetcd
  and its siblings for now. The pattern generalizes; the initial
  setup is scoped.

## Status

Pre-alpha scaffolding. Scripts written; no VM provisioned yet.

## Quick start

```
cp proxmox.env.sample proxmox.env       # already-known good defaults
./scripts/provision.sh                  # build the forgejo VM
./scripts/install.sh                    # bring up Forgejo + runner via compose
./scripts/bootstrap.sh                  # create admin user, mirror fastetcd repo,
                                        # register the runner
```

After bootstrap, browse to `http://forcicd.g8.lo:3000`. The runner
should appear as registered. Push a commit to fastetcd `main` —
the mirror picks it up within ~1 minute and triggers the workflow.

## License

Apache 2.0.
