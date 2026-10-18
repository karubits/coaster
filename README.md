# dvd-backup

Insert a disc → it's backed up to [Immich](https://immich.app) and every local leftover is
deleted. No interaction, no UI. Built for the DVDs and photo CDs schools and photographers hand
out, so they end up in your photo library instead of a drawer.

| Disc | What happens | Immich album |
|---|---|---|
| **DVD-Video** (`VIDEO_TS`) | each title ripped, converted to H.264/AAC MP4 (deinterlaced if needed, square pixels), dated with the disc's authoring date | `IMMICH_ALBUM` (default "DVD Uploads") |
| **Photo / data CD or DVD** | photos and videos copied off and uploaded **as originals** (Immich reads EXIF dates) | `IMMICH_PHOTO_ALBUM` (default "Photo Discs") |
| Both (slideshow DVD + JPEG folder) | both of the above | both |
| Audio CD | ignored | – |
| Unreadable / damaged disc | Gotify alert "Disc can't be read", disc ejected | – |

The disc is ejected as soon as it has been read, so you can insert the next one while the
previous one is still converting/uploading. A disc that was already uploaded is recognised and
ejected without re-uploading. Optional [Gotify](https://gotify.net) notifications on success and
failure.

## How it works

```
disc inserted ─► udev (99-dvd-backup.rules) ─► dvd-backup@sr0.service ─► dvd-backup.sh /dev/sr0
                                                                          │
   mount read-only ─► fingerprint (skip if already in done.log) ─► rip/copy to WORK_ROOT ─► eject
   ─► convert DVD titles ─► upload (POST /api/assets) ─► add to album ─► record + delete WORK_ROOT
```

- **Resume:** if anything fails after the disc was read (network, Immich down, API key
  permissions), the work dir is kept. Fix the cause and run
  `systemctl start dvd-backup-resume` — no disc needed. Uploads are tracked per file, so a resume
  never uploads twice.
- **Damaged discs:** some drives don't fail a bad read quickly — they time out, reset (USB) and
  eventually drop off the bus, *before* udev ever reports a disc. `dvd-backup-watch.service`
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
  `asset.upload`, `album.read`, `album.create`, `albumAsset.create`
- Free space in `WORK_ROOT` for one disc (≤ ~9 GB for a dual-layer DVD)
- Optional: Gotify server + app token; an Intel/AMD iGPU for `ENCODER=vaapi`

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
needs **libdvdcss**, which libdvdread loads automatically if it's installed. dvd-backup does not
ship or install it.

**Circumventing CSS is restricted or illegal in many countries** — e.g. the US (DMCA), much of the
EU, and Japan (since 2012, even for private copies). Only install libdvdcss where that's lawful
for your use. If you do: Debian/Ubuntu `sudo apt install libdvd-pkg && sudo dpkg-reconfigure
libdvd-pkg` (contrib/multiverse); Fedora `libdvdcss` from RPM Fusion tainted; Arch `libdvdcss`.

## Install

```bash
git clone https://github.com/Karubits/dvd-backup.git && cd dvd-backup
sudo install -m 0755 dvd-backup.sh /usr/local/sbin/dvd-backup.sh
sudo install -m 0644 systemd/dvd-backup@.service systemd/dvd-backup-resume.service \
    systemd/dvd-backup-watch.service /etc/systemd/system/
sudo install -m 0644 udev/99-dvd-backup.rules /etc/udev/rules.d/
sudo install -d -m 0700 /etc/dvd-backup
sudo install -m 0600 dvd-backup.env.example /etc/dvd-backup/env
sudoedit /etc/dvd-backup/env          # IMMICH_URL, IMMICH_API_KEY, optional GOTIFY_*
sudo systemctl daemon-reload && sudo udevadm control --reload
sudo systemctl enable --now dvd-backup-watch
```

Insert a disc and follow `journalctl -fu dvd-backup@sr0`.

**`WORK_ROOT` outside `/var/lib/dvd-backup`:** the units run with `ProtectSystem=strict`, so allow
the path with a drop-in for both `dvd-backup@.service` and `dvd-backup-resume.service`:

```bash
sudo systemctl edit dvd-backup@.service     # and: sudo systemctl edit dvd-backup-resume.service
# [Service]
# ReadWritePaths=/mnt/data/dvd-backup
```

## Configuration

All settings live in `/etc/dvd-backup/env` — see [`dvd-backup.env.example`](dvd-backup.env.example).

| Variable | Default | |
|---|---|---|
| `IMMICH_URL`, `IMMICH_API_KEY` | – | required |
| `IMMICH_ALBUM` | `DVD Uploads` | album for DVD-Video titles |
| `IMMICH_PHOTO_ALBUM` | `Photo Discs` | album for photos/videos from data discs |
| `GOTIFY_URL`, `GOTIFY_TOKEN` | – | notifications (optional) |
| `WORK_ROOT` | `/var/lib/dvd-backup/work` | scratch space, emptied after each disc |
| `MIN_TITLE_SECONDS` | `20` | shorter DVD titles are treated as menus/intros |
| `ENCODER` | `x264` | `x264` (CPU, best quality/size) or `vaapi` (iGPU) |
| `X264_PRESET`, `X264_CRF` | `slow`, `18` | |
| `VAAPI_QP`, `VAAPI_DEVICE` | `20`, `/dev/dri/renderD128` | |
| `AUDIO_BITRATE` | `192k` | |

## Usage

```bash
journalctl -fu dvd-backup@sr0                    # watch a run
journalctl -fu dvd-backup-watch                  # damaged-disc alerts
sudo udevadm trigger --action=change /dev/sr0    # re-run for the disc already in the drive
sudo systemctl start dvd-backup-resume           # finish failed runs without the disc
# dry run: read + convert only, output kept in WORK_ROOT, nothing uploaded or deleted
sudo bash -c 'set -a; . /etc/dvd-backup/env; DRY_RUN=1 /usr/local/sbin/dvd-backup.sh /dev/sr0'
# force a re-upload of a disc: delete its line from /var/lib/dvd-backup/done.log
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
  Immich API key, then `systemctl start dvd-backup-resume`.

## License

[MIT](LICENSE)
