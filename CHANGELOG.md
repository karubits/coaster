# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), newest first.

## 2026-10-18

### Changed
- **Renamed from dvd-backup to coaster**: script `/usr/local/sbin/coaster`, units
  `coaster@.service`, `coaster-resume.service`, `coaster-watch.service`, config
  `/etc/coaster/env`, state `/var/lib/coaster`. `setup.sh` migrates an existing dvd-backup
  install (config, ledger and unfinished work move over, old units are removed).
- Units hardened further (kernel modules/logs, hostname, realtime, SUID, namespaces,
  personality, native syscalls, address families): `systemd-analyze security` 8.3 → 6.1.
- Config errors are reported (and notified) together instead of failing on the first one;
  Immich settings are only required with `DESTINATION=immich`.
- Notification titles say "Disc backed up" instead of "… to Immich".

### Added
- `setup.sh --libdvdcss`: installs libdvdcss for copy-protected DVDs (Debian/Ubuntu via
  libdvd-pkg, Fedora via RPM Fusion tainted, Arch) — opt-in, see the legal note in the README.
- CI (GitHub + Forgejo): `tests/lint.sh` (shellcheck with extra optional checks,
  `systemd-analyze verify`, exposure-score gate), `tests/smoke.sh` (modes against a mock
  Immich/notification server), gitleaks over the whole history. `SECURITY.md`.
- `DESTINATION=path`: save discs to `SAVE_DIR/<date> <label>/` instead of, or as well as,
  uploading to Immich (`SAVE_OWNER` to chown the files). Resumable like uploads.
- Notification backends ntfy, Pushover and webhook (generic JSON, Slack/Mattermost, Discord)
  next to Gotify; `NOTIFY` selects them (`auto` = every configured one, the old behaviour).
- `setup.sh`: install, update (`--pull`), reconfigure, test notifications, uninstall. Re-runs
  replace only changed files, keep the env file (new settings appended commented out) and
  generate the systemd sandbox drop-ins for `SAVE_DIR` / `WORK_ROOT`.
- `coaster --check`, `--test-notify`, `--version`.

### Fixed
- Security: the Immich API key, notification tokens and webhook URL were passed to curl as
  command-line arguments, readable by any local user while a request ran.
- An unreachable Immich now shows "no connection" in the failure notification instead of
  an unexpected-response error.
- Gotify messages starting with `@` or `<` were read by curl as file names.
