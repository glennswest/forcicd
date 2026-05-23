# Changelog

## [Unreleased]

### 2026-05-23
- **chore:** Move VMID from 114 → 115 (114 already held by `registry.gw.lo` LXC).
- **fix:** Add `FORGEJO__security__INSTALL_LOCK=true` + sqlite DB defaults so the
  first-run install wizard is skipped — `bootstrap.sh` drives setup over the API.
- **fix:** Disable Forgejo's builtin SSH server (the `forgejo:9` image already
  binds OpenSSH on container :22, causing a port conflict). Git operations go
  over HTTP on the LAN.
- **feat:** Provisioned `forcicd.g8.lo` (VMID 115, 192.168.8.154) on pve.g8.lo;
  Forgejo + act_runner stack up. Web at http://forcicd.g8.lo:3000.

### 2026-05-21
- **chore:** Initial scaffolding. README, CLAUDE.md, design notes,
  scripts skeleton. No runnable infrastructure yet.
