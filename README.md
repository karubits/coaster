# coaster

[![CI](https://github.com/Karubits/coaster/actions/workflows/ci.yml/badge.svg)](https://github.com/Karubits/coaster/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Karubits/coaster?sort=semver)](https://github.com/Karubits/coaster/releases)
[![License: MIT](https://img.shields.io/github/license/Karubits/coaster)](LICENSE)
[![Renovate](https://img.shields.io/badge/renovate-enabled-brightgreen?logo=renovatebot)](renovate.json)

*A disc's last job before it becomes a coaster.*

Got a drawer full of DVDs and photo CDs from school plays, weddings and photographers?
coaster turns a Linux box with a DVD drive into a drop-in slot: **insert a disc, wait for it to
eject, insert the next.** Every disc ends up in [Immich](https://immich.app) and/or a folder,
with no clicking and no UI. It's for self-hosters who run Immich or a NAS and are comfortable
with a terminal for the one-time setup.

> **Vibe-coded, with care.** coaster was built with
> [Claude Opus 5.5](https://www.anthropic.com/claude) (Anthropic's AI) — see
> [how it was made](#how-this-was-made).

| Disc | What you get |
|---|---|
| **DVD-Video** | one MP4 (H.264/AAC) per title, deinterlaced, square pixels, dated with the disc's authoring date → Immich album "DVD Uploads" |
| **Photo / data CD or DVD** | the photos and videos on it, **as originals** (Immich reads EXIF dates) → Immich album "Photo Discs" |
| Both (e.g. slideshow DVD + JPEG folder) | both of the above |
| Already backed up | recognised and ejected, nothing done twice |
| Unreadable / damaged | notification "Disc can't be read", disc ejected |
| Audio CD | ignored |

Saving to a folder instead (or as well) gives `<folder>/<date> <disc label>/` with the same
files. The disc is ejected as soon as it has been read, so you can insert the next one while
the previous one is still converting. Optional notifications via Gotify, ntfy, Pushover or a
webhook (Slack, Mattermost, Discord, …).

## What you need

- **A DVD drive**, USB or internal. A CD-only drive only handles CDs; Blu-ray drives read
  everything. Several drives work, one disc at a time.
- **A Linux machine with systemd** (Debian/Ubuntu, Fedora, Arch, openSUSE; developed on
  Debian 13), with room for one disc in `/var/lib/coaster` (≤ 9 GB).
- **Somewhere to put the files:** an Immich server (tested with v3.3) with an API key that has
  `asset.upload`, `album.read`, `album.create`, `albumAsset.create`, and/or a folder (local
  disk, NFS/SMB mount, …).

The software it needs (ffmpeg ≥ 7, curl, jq, eject) is installed by the setup script.

## Install

```bash
git clone https://github.com/Karubits/coaster.git && cd coaster
./setup.sh
```

The script asks for sudo and walks you through it:

1. lists the packages it's missing and installs them only if you say yes (apt, dnf, pacman or
   zypper). Say no and it carries on, but warns: coaster won't run until they're installed.
   If a package needs a repository that isn't enabled (Fedora: RPM Fusion for ffmpeg), it
   shows exactly what would change and asks first; nothing is changed without a yes,
2. installs coaster and asks where backups go (Immich URL + API key, and/or a folder) and how
   to notify you,
3. checks the config, offers a test notification and starts watching the drive.

Then insert a disc. To follow along: `journalctl -fu coaster@sr0`.

**Update:** `./setup.sh --pull` — pulls the latest version and installs only what changed. Your
settings are kept; new ones are added to `/etc/coaster/env` commented out (see the
[CHANGELOG](CHANGELOG.md)).

| `setup.sh` option | |
|---|---|
| `--pull` | `git pull` first, then update |
| `--configure` | answer the setup questions again |
| `--test-notify` | send a test notification |
| `--install-deps` | install missing packages without asking |
| `--libdvdcss` | install libdvdcss for [copy-protected DVDs](#copy-protected-commercial-dvds) |
| `--enable-repos` | allow enabling a needed package repository without asking (for unattended runs) |
| `--yes` | never ask (unattended; set up `/etc/coaster/env` yourself) |
| `--uninstall [--purge]` | remove coaster; `--purge` also deletes settings and history |

Prefer to do it by hand? See [Manual install](#manual-install).

## Day to day

Insert a disc; it's ejected when read and a notification arrives when it's backed up (about
¼ of the video's running time for DVDs, e.g. ~15 min for an hour). Multi-title DVDs give one
video per title (`<label> <date> tNN.mp4`); a "play all" title comes along as an extra video.

```bash
journalctl -fu coaster@sr0                      # watch a backup
sudo systemctl start coaster-resume             # finish failed backups (no disc needed)
sudo udevadm trigger --action=change /dev/sr0   # re-run for the disc in the drive
sudo ./setup.sh --test-notify                   # test notifications
# back up a disc again: delete its line from /var/lib/coaster/done.log
```

**If something fails** after the disc was read (Immich down, network, a missing API key
permission, a folder that isn't mounted), nothing is lost: the copy is kept, the notification
says why. Fix the cause and run `sudo systemctl start coaster-resume`; files already done
aren't done again.

## Configuration

Settings live in `/etc/coaster/env` (`sudo ./setup.sh --configure` edits the main ones; all
of them are explained in [`coaster.env.example`](coaster.env.example)).

| Variable | Default | |
|---|---|---|
| `DESTINATION` | `immich` | `immich`, `path`, or both (`"immich path"`) |
| `IMMICH_URL`, `IMMICH_API_KEY` | – | for `immich` |
| `IMMICH_ALBUM`, `IMMICH_PHOTO_ALBUM` | `DVD Uploads`, `Photo Discs` | albums for videos / photo discs |
| `SAVE_DIR` | – | for `path`; must exist (a missing one counts as "not mounted") |
| `SAVE_OWNER` | – | `user:group` for saved files (otherwise root) |
| `NOTIFY` | `auto` | `auto` (every service configured below), `none`, or a list: `ntfy,gotify` |
| `GOTIFY_URL`, `GOTIFY_TOKEN` | – | Gotify |
| `NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN` | `https://ntfy.sh` | ntfy (token only for protected topics) |
| `PUSHOVER_TOKEN`, `PUSHOVER_USER` | – | Pushover |
| `WEBHOOK_URL`, `WEBHOOK_FORMAT`, `WEBHOOK_HEADER` | `json` | JSON `{title, message, priority, host}`, or `slack` (also Mattermost, Rocket.Chat) / `discord`; one extra header, e.g. auth |
| `WORK_ROOT` | `/var/lib/coaster/work` | scratch space for one disc |
| `ENCODER` | `x264` | `x264` (CPU, best quality) or `vaapi` (Intel/AMD iGPU, faster) |
| `MIN_TITLE_SECONDS` | `20` | shorter DVD titles are menus/intros and skipped |
| `X264_PRESET`, `X264_CRF`, `VAAPI_QP`, `AUDIO_BITRATE` | `slow`, `18`, `20`, `192k` | encoder quality |

After changing `SAVE_DIR` or `WORK_ROOT` by hand, re-run `./setup.sh` — the services may only
write to the paths it allows.

## Copy-protected commercial DVDs

Home-made discs (school plays, weddings, photographer DVDs, photo CDs) are **not**
copy-protected and need nothing extra. Commercial movie DVDs use CSS encryption, and reading
them needs **libdvdcss**. **Circumventing CSS is restricted or illegal in many countries** —
e.g. the US (DMCA), much of the EU, and Japan (since 2012, even for private copies). coaster
doesn't install it unless you ask: only run `./setup.sh --libdvdcss` where that's lawful for
your use. On Debian/Ubuntu it comes from the `contrib`/`multiverse` repository component, on
Fedora from RPM Fusion tainted; if that isn't enabled yet, setup shows the change and asks.

## How it works

```
disc inserted ─► udev rule ─► coaster@sr0.service ─► coaster /dev/sr0
   mount read-only ─► fingerprint (skip if in done.log) ─► copy/rip to WORK_ROOT ─► eject
   ─► convert DVD titles ─► save to SAVE_DIR and/or upload to Immich ─► record ─► clean up
```

- **Damaged discs:** some drives hang on a bad disc before Linux ever reports it inserted.
  `coaster-watch` follows the kernel log for drive timeouts and USB resets, alerts you and
  ejects the disc.
- **Any drive, any port:** drives are found as they appear (`sr0`, `sr1`, …); nothing to
  configure when you swap drives or USB ports.
- **Locked down:** the services run in a systemd sandbox that can only write to its state
  directory and the folders you configured; the disc is mounted read-only. See
  [SECURITY.md](SECURITY.md).

## Troubleshooting

- **Nothing happens on insert:** run `udevadm monitor --udev --property` while inserting; you
  should see `ID_CDROM_MEDIA=1` and `ID_CDROM_MEDIA_TRACK_COUNT_DATA=1`. No event at all → the
  drive can't read the disc; check `journalctl -k` for `sr0` errors.
- **"Missing required permission: …":** add that permission to the Immich API key, then
  `sudo systemctl start coaster-resume`.
- **"SAVE_DIR … does not exist (not mounted?)":** mount the share, then
  `sudo systemctl start coaster-resume`. On NFS with `root_squash` the folder must be writable
  by the squashed user, and `SAVE_OWNER` can't take effect.
- **A damaged disc isn't caught:** drives fail in different ways — run `journalctl -kf` while
  inserting it and open an issue with what you see.
- **Check the settings:** re-run `./setup.sh`; it ends with a config check.

## Manual install

For those who'd rather not run `setup.sh`. Install the packages first:

```bash
sudo apt install ffmpeg curl jq eject       # Debian / Ubuntu
sudo dnf install ffmpeg curl jq eject       # Fedora (ffmpeg from RPM Fusion)
sudo pacman -S ffmpeg curl jq util-linux    # Arch
```

ffmpeg must be ≥ 7.0 with the `dvdvideo` demuxer (`ffmpeg -demuxers | grep dvdvideo`).

```bash
# 1. Script, services, udev rule
sudo install -m 0755 coaster.sh /usr/local/sbin/coaster
sudo install -m 0644 systemd/coaster@.service systemd/coaster-resume.service \
    systemd/coaster-watch.service /etc/systemd/system/
sudo install -m 0644 udev/99-coaster.rules /etc/udev/rules.d/

# 2. Settings (root only: they hold API keys)
sudo install -d -m 0700 /etc/coaster
sudo install -m 0600 coaster.env.example /etc/coaster/env
sudoedit /etc/coaster/env
```

3. **Only with `SAVE_DIR`, or a `WORK_ROOT` outside `/var/lib/coaster`:** allow the services to
   write there. Create this file as both
   `/etc/systemd/system/coaster@.service.d/50-paths.conf` and
   `/etc/systemd/system/coaster-resume.service.d/50-paths.conf`:

   ```ini
   [Service]
   # "-" = may be missing (e.g. an unmounted share) without blocking the service
   ReadWritePaths=-/srv/media/discs
   # only if a path is under /home, /root or /run/user:
   #ProtectHome=read-only
   ```

```bash
# 4. Start
sudo systemctl daemon-reload && sudo udevadm control --reload
sudo systemctl enable --now coaster-watch

# 5. Test the settings and notifications
sudo systemd-run --pipe --wait -p EnvironmentFile=/etc/coaster/env /usr/local/sbin/coaster --check
sudo systemd-run --pipe --wait -p EnvironmentFile=/etc/coaster/env /usr/local/sbin/coaster --test-notify
```

**Update:** `git pull`, repeat step 1, compare `/etc/coaster/env` with `coaster.env.example`,
then `sudo systemctl daemon-reload && sudo systemctl restart coaster-watch`.
**Uninstall:**

```bash
sudo systemctl disable --now coaster-watch
sudo rm -rf /etc/systemd/system/coaster{@,-resume,-watch}.service{,.d} \
    /etc/udev/rules.d/99-coaster.rules /usr/local/sbin/coaster
sudo systemctl daemon-reload && sudo udevadm control --reload
sudo rm -rf /etc/coaster /var/lib/coaster   # settings + history, if you don't want them
```

## Development

```bash
tests/lint.sh    # shellcheck, systemd-analyze verify + security score, VERSION ↔ CHANGELOG
tests/smoke.sh   # the script's modes against a mock Immich + notification server
                 # (no disc, root or network; needs ffmpeg, jq, curl, python3)
```

CI runs both, plus a [gitleaks](https://github.com/gitleaks/gitleaks) secret scan, on every
push and pull request; [Renovate](renovate.json) keeps the CI tooling up to date. Versions
follow [SemVer](https://semver.org) — see the [CHANGELOG](CHANGELOG.md). Security issues:
[SECURITY.md](SECURITY.md).

## How this was made

coaster was written with Claude Opus 5.5 as a coding assistant: I described what I wanted, the
AI wrote most of the code, and I reviewed it, tested it with real discs and run it on my own
server. To make up for that, every change goes through the checks above (shellcheck, a hardened
and scored systemd sandbox, smoke tests, secret scanning), and the [CHANGELOG](CHANGELOG.md)
records what changed and why. It's still a hobby project shared as is (see the
[license](LICENSE)): read the script before running it as root, try it with a few discs first,
and please [report](SECURITY.md) anything that looks wrong.

## License

[MIT](LICENSE)
