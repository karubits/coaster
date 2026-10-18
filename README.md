# coaster

*A disc's last job before it becomes a coaster.*

Insert a disc → it's backed up to [Immich](https://immich.app) and/or a folder, and every local
leftover is deleted. No interaction, no UI. Built for the DVDs and photo CDs schools and
photographers hand out, so they end up in your photo library instead of a drawer.

| Disc | What happens | Immich album (`DESTINATION=immich`) |
|---|---|---|
| **DVD-Video** (`VIDEO_TS`) | each title ripped, converted to H.264/AAC MP4 (deinterlaced if needed, square pixels), dated with the disc's authoring date | `IMMICH_ALBUM` (default "DVD Uploads") |
| **Photo / data CD or DVD** | photos and videos copied off and uploaded **as originals** (Immich reads EXIF dates) | `IMMICH_PHOTO_ALBUM` (default "Photo Discs") |
| Both (slideshow DVD + JPEG folder) | both of the above | both |
| Audio CD | ignored | – |
| Unreadable / damaged disc | alert "Disc can't be read", disc ejected | – |

With `DESTINATION=path` the same files go to `SAVE_DIR/<date> <label>/` instead (videos on top,
data-disc files in the disc's folder structure, dates kept as file times) — or to both.

The disc is ejected as soon as it has been read, so you can insert the next one while the
previous one is still converting/uploading. A disc that was already backed up is recognised and
ejected without doing it again. Optional notifications on success and failure via
[Gotify](https://gotify.net), [ntfy](https://ntfy.sh), [Pushover](https://pushover.net) or a
webhook (generic JSON, Slack/Mattermost, Discord) — pick one or several.

## How it works

```
disc inserted ─► udev (99-coaster.rules) ─► coaster@sr0.service ─► coaster /dev/sr0
                                                                          │
   mount read-only ─► fingerprint (skip if already in done.log) ─► rip/copy to WORK_ROOT ─► eject
   ─► convert DVD titles ─► save to SAVE_DIR and/or upload + add to album ─► record + delete WORK_ROOT
```

- **Resume:** if anything fails after the disc was read (network, Immich down, API key
  permissions, `SAVE_DIR` not mounted), the work dir is kept. Fix the cause and run
  `systemctl start coaster-resume` — no disc needed. Uploads and saved files are tracked per
  file, so a resume never does one twice.
- **Damaged discs:** some drives don't fail a bad read quickly — they time out, reset (USB) and
  eventually drop off the bus, *before* udev ever reports a disc. `coaster-watch.service`
  follows the kernel log for SCSI timeouts / device-offline on `sr*` and USB resets of the port an
  optical drive is attached to, then alerts and tries to eject. (Healthy CD-Rs give one instant
  "Illegal mode for this track" error at their run-out blocks; that is ignored.)
- **Any drive, any port:** devices are taken from udev (`sr0`, `sr1`, …) and the watcher looks up
  each drive's USB port at event time, so swapping ports or drives needs no config. Internal SATA
  drives work too (the watcher then relies on the timeout/offline messages). Multiple drives are
  processed one disc at a time.

## Requirements

- Linux with systemd + udev (developed on Debian 13; any recent distro should do)
- `ffmpeg` ≥ 7.0 (needs the `dvdvideo` demuxer: `ffmpeg -demuxers | grep dvdvideo`), `curl`, `jq`,
  `eject`, util-linux (`mount`, `flock`, `blockdev`)
- Immich with an API key — tested against **Immich v3.3**. Permissions:
  `asset.upload`, `album.read`, `album.create`, `albumAsset.create` — or, instead, a folder to
  save to (local disk, NFS/SMB mount, …)
- Free space in `WORK_ROOT` for one disc (≤ ~9 GB for a dual-layer DVD)
- Optional: Gotify, ntfy, Pushover or a webhook for notifications; an Intel/AMD iGPU for
  `ENCODER=vaapi`

```bash
# Debian / Ubuntu
sudo apt install ffmpeg curl jq eject
# Fedora (ffmpeg from RPM Fusion)
sudo dnf install ffmpeg curl jq eject
# Arch
sudo pacman -S ffmpeg curl jq util-linux
```

### Copy-protected (CSS) commercial DVDs — optional, check your local law

Home-made discs (school performances, weddings, photographer DVDs, photo CDs) are **not**
copy-protected and need nothing extra. Commercial movie DVDs use CSS encryption; reading them
needs **libdvdcss**, which libdvdread loads automatically if it's installed. coaster does not
ship or install it.

**Circumventing CSS is restricted or illegal in many countries** — e.g. the US (DMCA), much of the
EU, and Japan (since 2012, even for private copies). Only install libdvdcss where that's lawful
for your use. If you do: `./setup.sh --libdvdcss` installs it (Debian/Ubuntu: `libdvd-pkg` from
contrib/multiverse, which builds it; Fedora: RPM Fusion tainted; Arch: `libdvdcss`).

## Install

```bash
git clone https://github.com/Karubits/coaster.git && cd coaster
./setup.sh                 # asks for sudo, then: Immich and/or folder, notifications
```

`setup.sh` checks the dependencies (`--install-deps` installs missing ones), installs the script,
units and udev rule, creates `/etc/coaster/env` and asks for the settings, enables the
watcher, then tests the config inside the service sandbox and offers a test notification. Insert
a disc and follow `journalctl -fu coaster@sr0`.

**Updating:** `./setup.sh --pull` (or `git pull && ./setup.sh`). Re-runs only replace files that
changed, keep your env file (settings new in that version are appended to it commented out),
regenerate the sandbox drop-ins and restart the watcher when needed. A backup that's running
finishes on the version it started with. Downgrades are refused unless `--force`.

**Coming from dvd-backup** (the old name): run `./setup.sh` from the renamed checkout. It
removes the old units, moves `/etc/dvd-backup` → `/etc/coaster` and `/var/lib/dvd-backup` →
`/var/lib/coaster` (ledger and unfinished work included) and installs coaster.

| `setup.sh` option | |
|---|---|
| `--pull` | `git pull` the checkout first (as its owner), then update |
| `--configure` | ask the setup questions again |
| `--test-notify` | send a test notification |
| `--install-deps` | install missing packages (apt, dnf, pacman, zypper) |
| `--libdvdcss` | install libdvdcss for copy-protected DVDs — [check your local law](#copy-protected-css-commercial-dvds--optional-check-your-local-law) |
| `--yes` | never ask (first install: edit `/etc/coaster/env` by hand, then re-run) |
| `--uninstall [--purge]` | remove coaster; `--purge` also deletes config and state |

**Sandbox:** the units run with `ProtectSystem=strict`. `setup.sh` writes a drop-in
(`<unit>.d/50-paths.conf`) that allows `SAVE_DIR` and a `WORK_ROOT` outside
`/var/lib/coaster` — re-run it after changing either by hand.

### Manual install (without setup.sh)

Everything `setup.sh` does, by hand. Install the [requirements](#requirements) first.

```bash
git clone https://github.com/Karubits/coaster.git && cd coaster

# 1. Script, units, udev rule
sudo install -m 0755 coaster.sh /usr/local/sbin/coaster
sudo install -m 0644 systemd/coaster@.service systemd/coaster-resume.service \
    systemd/coaster-watch.service /etc/systemd/system/
sudo install -m 0644 udev/99-coaster.rules /etc/udev/rules.d/

# 2. Config (root only: it holds API keys/tokens)
sudo install -d -m 0700 /etc/coaster
sudo install -m 0600 coaster.env.example /etc/coaster/env
sudoedit /etc/coaster/env          # DESTINATION, IMMICH_* and/or SAVE_DIR, NOTIFY + backend
```

3. **Only if `SAVE_DIR` is set, or `WORK_ROOT` is outside `/var/lib/coaster`:** the units run
   with `ProtectSystem=strict`, so allow those paths. Put the same drop-in into both
   `/etc/systemd/system/coaster@.service.d/50-paths.conf` and
   `/etc/systemd/system/coaster-resume.service.d/50-paths.conf`:

   ```ini
   [Service]
   # "-" = the path may be missing (e.g. an unmounted share) without blocking the unit
   ReadWritePaths=-/srv/media/discs
   ReadWritePaths=-/mnt/data/coaster-work
   # only if one of the paths is under /home, /root or /run/user:
   #ProtectHome=read-only
   ```

```bash
# 4. Activate
sudo systemctl daemon-reload && sudo udevadm control --reload
sudo systemctl enable --now coaster-watch

# 5. Test the config and the notifications (same sandbox as the service, minus the drop-in)
sudo systemd-run --pipe --wait -p EnvironmentFile=/etc/coaster/env /usr/local/sbin/coaster --check
sudo systemd-run --pipe --wait -p EnvironmentFile=/etc/coaster/env /usr/local/sbin/coaster --test-notify
```

**Updating by hand:** `git pull`, repeat step 1, compare `/etc/coaster/env` with
`coaster.env.example` for new settings (see [CHANGELOG](CHANGELOG.md)), then
`sudo systemctl daemon-reload && sudo systemctl restart coaster-watch`. Install the script with
`install` as above (it replaces the file instead of rewriting it), so a running backup isn't
disturbed.

**Uninstalling by hand:**

```bash
sudo systemctl disable --now coaster-watch
sudo rm -rf /etc/systemd/system/coaster{@,-resume,-watch}.service{,.d} \
    /etc/udev/rules.d/99-coaster.rules /usr/local/sbin/coaster
sudo systemctl daemon-reload && sudo udevadm control --reload
# config + ledger + unfinished work, if you don't want to keep them:
sudo rm -rf /etc/coaster /var/lib/coaster
```

## Configuration

All settings live in `/etc/coaster/env` — see [`coaster.env.example`](coaster.env.example).

| Variable | Default | |
|---|---|---|
| `DESTINATION` | `immich` | `immich`, `path`, or both (`"immich path"`) |
| `IMMICH_URL`, `IMMICH_API_KEY` | – | required for `immich` |
| `IMMICH_ALBUM` | `DVD Uploads` | album for DVD-Video titles |
| `IMMICH_PHOTO_ALBUM` | `Photo Discs` | album for photos/videos from data discs |
| `SAVE_DIR` | – | required for `path`; must exist (a missing one counts as "not mounted") |
| `SAVE_OWNER` | – | `user:group` for saved files (otherwise root) |
| `NOTIFY` | `auto` | `auto` (every backend configured below), `none`, or a list: `ntfy,gotify` |
| `GOTIFY_URL`, `GOTIFY_TOKEN` | – | Gotify |
| `NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN` | `https://ntfy.sh`, –, – | ntfy (token only for protected topics) |
| `PUSHOVER_TOKEN`, `PUSHOVER_USER` | – | Pushover app token + user key |
| `WEBHOOK_URL`, `WEBHOOK_FORMAT`, `WEBHOOK_HEADER` | –, `json`, – | POST `{title, message, priority, host}`; `slack` (also Mattermost, Rocket.Chat) or `discord` payloads; one extra header, e.g. auth |
| `WORK_ROOT` | `/var/lib/coaster/work` | scratch space, emptied after each disc |
| `MIN_TITLE_SECONDS` | `20` | shorter DVD titles are treated as menus/intros |
| `ENCODER` | `x264` | `x264` (CPU, best quality/size) or `vaapi` (iGPU) |
| `X264_PRESET`, `X264_CRF` | `slow`, `18` | |
| `VAAPI_QP`, `VAAPI_DEVICE` | `20`, `/dev/dri/renderD128` | |
| `AUDIO_BITRATE` | `192k` | |

## Usage

```bash
journalctl -fu coaster@sr0                    # watch a run
journalctl -fu coaster-watch                  # damaged-disc alerts
sudo ./setup.sh --test-notify                    # test notifications
sudo udevadm trigger --action=change /dev/sr0    # re-run for the disc already in the drive
sudo systemctl start coaster-resume           # finish failed runs without the disc
# dry run: read + convert only, output kept in WORK_ROOT, nothing saved, uploaded or deleted
sudo bash -c 'set -a; . /etc/coaster/env; DRY_RUN=1 /usr/local/sbin/coaster /dev/sr0'
# back up a disc again: delete its line from /var/lib/coaster/done.log
```

Multi-title DVDs produce one video per title (`<label> <date> tNN.mp4`). If a disc also has a
"play all" title, you'll get that as an extra video.

## Troubleshooting

- **Nothing happens on insert:** `udevadm monitor --udev --property` while inserting — you should
  see `ID_CDROM_MEDIA=1` and `ID_CDROM_MEDIA_TRACK_COUNT_DATA=1`. No event at all → the drive
  couldn't read the disc; check `journalctl -k` for `sr0` errors.
- **A damaged disc isn't caught by the watcher:** drives fail in different ways. Run
  `journalctl -kf` while inserting it and open an issue with the lines you see.
- **`Missing required permission: …`** in the failure notification: add that permission to the
  Immich API key, then `systemctl start coaster-resume`.
- **`SAVE_DIR … does not exist (not mounted?)`:** mount the share, then
  `systemctl start coaster-resume`. On NFS with `root_squash`, the folder must be writable by
  the squashed user and `SAVE_OWNER` can't take effect.
- **Check the config:** `/usr/local/sbin/coaster --check` (with the env loaded) or just
  re-run `./setup.sh`, which runs the check inside the service sandbox.

## Development

```bash
tests/lint.sh     # shellcheck (+ optional checks in .shellcheckrc), systemd-analyze verify,
                  # systemd-analyze security (fails above exposure 6.5)
tests/smoke.sh    # check / test-notify / resume modes against a mock Immich + notification
                  # server — no disc, no root, no network (needs ffmpeg, jq, curl, python3)
```

CI runs both on every push and pull request, plus a [gitleaks](https://github.com/gitleaks/gitleaks)
secret scan of the whole history. The units are hardened as far as mounting and ejecting discs
allow (`ProtectSystem=strict`, private mounts, no new privileges, restricted namespaces and
address families, …); see `systemd-analyze security coaster@sr0`.

**Releases:** [Semantic Versioning](https://semver.org). To release: bump `VERSION` in
`coaster.sh`, add a `## [X.Y.Z] - date` section to [CHANGELOG.md](CHANGELOG.md) (lint checks
they match), commit, `git tag -a vX.Y.Z -m vX.Y.Z && git push --follow-tags`. `setup.sh` shows
the version change on update and refuses downgrades.

Security issues: see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
