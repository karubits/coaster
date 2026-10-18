# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), newest first. Versions follow
[Semantic Versioning](https://semver.org); each one is a git tag `vX.Y.Z` (and a release).

## [0.4.3] - 2026-10-18

### Fixed
- The missing-program check from 0.4.2 also required the drive tools (eject, udevadm, …)
  for `--resume`, which doesn't use the drive. They're now only required for disc runs and
  `--check`.

## [0.4.2] - 2026-10-18

### Changed
- `setup.sh` lists missing packages with the install command and installs them only after an
  explicit yes; declining (or `--yes` without `--install-deps`) continues with a warning
  instead of stopping.
- coaster checks for the programs it needs and fails with "missing program: …" (log,
  `--check`, failure notification) instead of a later, unclear error.
- Releases are created by the release workflow (run by hand), which also makes the tag;
  optional `RELEASE_TOKEN` secret to publish as a bot account.
- README reorganised for first-time users: what you need → install → day to day; package
  lists only under Manual install.

## [0.4.1] - 2026-10-18

### Added
- Release automation: the release workflow (run by hand on Forgejo) tags the commit
  `v<VERSION>` and publishes the release with the version's CHANGELOG section as notes; the
  GitHub mirror creates its release when the tag arrives (`tools/release-notes.sh`).
- Renovate (`renovate.json`, weekly on Forgejo): PRs for the pinned CI actions, gitleaks and
  Renovate itself, after a 7-day release age.
- README badges: CI, release, license, Renovate.

### Changed
- CI verifies the gitleaks download against its published checksums.

## [0.4.0] - 2026-10-18

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

## [0.3.0] - 2026-10-18

### Changed
- Portable defaults for a public release: `WORK_ROOT` defaults to `/var/lib/dvd-backup/work`,
  notifications name the actual drive, README for outsiders, libdvdcss optional with a legal
  note. MIT license, shellcheck CI.

## [0.2.4] - 2026-10-18

### Changed
- The watcher logs whether its eject succeeded.

## [0.2.3] - 2026-10-18

### Fixed
- The watcher alerted nothing for 10 minutes after a (re)start.

## [0.2.2] - 2026-10-18

### Added
- The watcher also alerts on USB resets of the optical drive's port.

## [0.2.1] - 2026-10-18

### Fixed
- Crash on the first upload, UTF-8 labels under systemd, mounting by filesystem type.

## [0.2.0] - 2026-10-18

### Added
- Photo/data CD and DVD import (originals → `IMMICH_PHOTO_ALBUM`), alerts for unreadable
  discs (`dvd-backup-watch`), Immich's error message in failure notifications.

## [0.1.1] - 2026-10-18

### Fixed
- Fingerprint includes file names, sizes and mtimes, so discs with the same label can't collide.

## [0.1.0] - 2026-10-18

### Added
- udev-triggered DVD rip → H.264/AAC MP4 → Immich upload, `--resume` mode and
  `dvd-backup-resume.service`.

[0.4.3]: https://github.com/Karubits/coaster/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/Karubits/coaster/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/Karubits/coaster/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Karubits/coaster/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Karubits/coaster/compare/v0.2.4...v0.3.0
[0.2.4]: https://github.com/Karubits/coaster/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/Karubits/coaster/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/Karubits/coaster/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/Karubits/coaster/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Karubits/coaster/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/Karubits/coaster/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Karubits/coaster/releases/tag/v0.1.0
