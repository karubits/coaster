# dvd-backup

Insert a DVD → it is ripped, converted to H.264/AAC MP4, uploaded to [Immich](https://immich.app)
into one album, and every local leftover is deleted. No interaction.

Built for school-performance DVDs on `zima` (homelab); deployed by the
[homelab-playbook](https://git.karubits.com/Karubits/homelab-playbook) (`tasks/dvd_backup.yml`).

## How it works

1. `udev/99-dvd-backup.rules` — on a DVD media-change event, `systemctl --no-block start dvd-backup@sr0`.
2. `systemd/dvd-backup@.service` — hardened oneshot running `dvd-backup.sh /dev/sr0`.
3. `dvd-backup.sh`:
   - mounts the disc read-only, fingerprints it (IFO hash + label) and skips/ejects discs already
     recorded in `/var/lib/dvd-backup/done.log`;
   - takes the **disc authoring date** (IFO mtime) as the video date;
   - rips every title ≥ `MIN_TITLE_SECONDS` with ffmpeg's `dvdvideo` demuxer (stream copy),
     falling back to raw VOB concatenation for discs with malformed IFOs (unencrypted only);
   - ejects the disc, then encodes each title: deinterlace if flagged, square pixels,
     H.264 High CRF 18 + AAC 192k, `+faststart`, `creation_time` set;
   - uploads via `POST /api/assets`, adds the assets to the album (created if missing);
   - records the fingerprint, deletes the work dir, sends a Gotify notification.
   - On failure: work dir is kept, Gotify alert, unit fails. Once the rip is done the disc isn't
     needed any more: fix the cause and `systemctl start dvd-backup-resume` finishes the pending work
     (convert/upload/album/cleanup). Re-inserting the disc also resumes it.

## Requirements

`ffmpeg` (≥ 7.0, for the `dvdvideo` demuxer), `curl`, `jq`, `eject`, `util-linux`.
CSS-encrypted discs need **libdvdcss2** (Debian: `libdvd-pkg` from contrib, then
`dpkg-reconfigure libdvd-pkg`); libdvdread loads it at runtime.

Immich API key permissions: `asset.upload`, `album.read`, `album.create`, `albumAsset.create`.

## Manual install

```bash
install -m 0755 dvd-backup.sh /usr/local/sbin/dvd-backup.sh
install -m 0644 systemd/dvd-backup@.service systemd/dvd-backup-resume.service /etc/systemd/system/
install -m 0644 udev/99-dvd-backup.rules /etc/udev/rules.d/
install -d -m 0700 /etc/dvd-backup && install -m 0600 dvd-backup.env.example /etc/dvd-backup/env  # edit it
systemctl daemon-reload && udevadm control --reload
```

## Usage

```bash
journalctl -fu dvd-backup@sr0                      # watch a run
sudo udevadm trigger --action=change /dev/sr0      # re-trigger for the disc in the drive
sudo systemctl start dvd-backup@sr0                # same, directly
sudo systemctl start dvd-backup-resume             # finish failed runs without the disc
# dry run (rip + convert only, output kept in WORK_ROOT):
sudo bash -c 'set -a; . /etc/dvd-backup/env; DRY_RUN=1 /usr/local/sbin/dvd-backup.sh /dev/sr0'
# force re-upload of a disc: remove its line from /var/lib/dvd-backup/done.log
```

Multi-title discs produce one video per title (`<label> <date> tNN.mp4`).
