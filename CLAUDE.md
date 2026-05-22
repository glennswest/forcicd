# CLAUDE.md — forcicd

Project-specific context. Cross-project rules live in `../CLAUDE.md`.

## Project summary

Local CI for fastetcd (and siblings) hosted on `pve.g8.lo`.
Forgejo + Forgejo Actions runner mirroring the GitHub workflow.
Native GitHub-Actions YAML compatibility means
`fastetcd/.github/workflows/ci.yml` runs unmodified.

## Version

**`0.0.1`** — initial scaffolding.

## Architecture pillars

- **Single VM** (`forcicd.g8.lo`, VMID 114, IP 192.168.8.154,
  Fedora 43 cloud). Splittable later.
- **Docker Compose stack** for Forgejo + act_runner. One file,
  two services, persistent volumes.
- **Local container registry** for the workflow's output images:
  `fastregistry.g10.lo` (already exists; mkube-owned).
- **Pull-mirror** from `github.com/glennswest/fastetcd` runs every
  60s. Workflow triggers on the mirror's main / tag events.

## Work plan

1. Project scaffold (this commit).
2. Cloud-init for `forcicd.g8.lo` (minimal — just SSH + QGA).
3. Provisioning script (reuses pattern from fastetcd_uptest).
4. Forgejo + act_runner install (docker-compose).
5. Bootstrap script:
   - create admin user (idempotent)
   - register a runner token
   - configure pull-mirror for fastetcd
6. First successful local CI run.

## Constraints

- **Do not duplicate the GitHub workflow.** The `.github/workflows/`
  file in fastetcd stays authoritative. Forgejo runs the same one
  via the pull-mirror.
- **No secrets in the repo.** `proxmox.env` is gitignored;
  Forgejo admin password is gitignored; runner token gets created
  on first bootstrap and lives only on the VM.
- **Idempotent install.** `install.sh` must be re-runnable.
  `bootstrap.sh` should detect existing state (admin already
  created, repo already mirrored, etc.) and skip safely.

## Sibling projects

- `../fastetcd` — the project being CI'd
- `../fastetcd_uptest` — provisioning patterns reused here
  (script structure, MicroDNS helpers, `qm`-over-ssh idioms)
