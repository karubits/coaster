# Security

coaster runs as root (it has to mount discs) and handles an Immich API key and notification
tokens, so security reports are welcome.

**Reporting:** please use GitHub's private vulnerability reporting
(*Security → Report a vulnerability*) on [Karubits/coaster](https://github.com/Karubits/coaster)
rather than a public issue. You'll get an answer within a week.

**Scope:** `coaster.sh`, `setup.sh`, the systemd units and the udev rule — e.g. command or path
injection through disc labels / file names, secrets leaking into logs or notifications, ways
out of the service sandbox.

**What's in place:**
- Config (`/etc/coaster/env`, API keys) is root-only (`0600`). The API key, tokens and webhook
  URL reach curl through a config on a pipe, never as command-line arguments (which any local
  user can read in `ps`).
- Discs are mounted read-only in a private mount namespace; disc labels are sanitised before
  they're used in file names; file names from the disc are never evaluated.
- Units: `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, restricted
  namespaces/address families/realtime/SUID — write access only to the state dir and the paths
  you configure.
- CI: shellcheck, `systemd-analyze verify` + `security` gate, smoke tests, gitleaks on the
  whole git history.
