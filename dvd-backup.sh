#!/usr/bin/env bash
# dvd-backup — rip a DVD-Video disc, convert each title to H.264/AAC MP4, upload it to
# Immich, add it to an album, then delete every local leftover.
#
# Started by udev (udev/99-dvd-backup.rules) via dvd-backup@<kernel-dev>.service when a
# DVD is inserted. Can also be run by hand:  sudo dvd-backup.sh /dev/sr0
#
# Config: environment (see dvd-backup.env.example), normally /etc/dvd-backup/env.
# CSS-encrypted discs need libdvdcss2 (Debian: libdvd-pkg); libdvdread dlopen()s it.
set -euo pipefail

DEVICE="${1:-/dev/sr0}"   # or --resume

: "${IMMICH_URL:?IMMICH_URL not set}"
: "${IMMICH_API_KEY:?IMMICH_API_KEY not set}"
IMMICH_ALBUM="${IMMICH_ALBUM:-DVD Uploads}"
GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"
WORK_ROOT="${WORK_ROOT:-/mnt/data/dvd-backup}"
STATE_DIR="${STATE_DIR:-/var/lib/dvd-backup}"
RUN_DIR="${RUN_DIR:-/run/dvd-backup}"
MIN_TITLE_SECONDS="${MIN_TITLE_SECONDS:-20}"
ENCODER="${ENCODER:-x264}"          # x264 | vaapi
X264_PRESET="${X264_PRESET:-slow}"
X264_CRF="${X264_CRF:-18}"
VAAPI_QP="${VAAPI_QP:-20}"
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
AUDIO_BITRATE="${AUDIO_BITRATE:-192k}"
DRY_RUN="${DRY_RUN:-0}"             # 1 = rip + convert only; no upload, no cleanup
EJECT="${EJECT:-1}"

IMMICH_URL="${IMMICH_URL%/}"
MNT="$RUN_DIR/mnt"
LEDGER="$STATE_DIR/done.log"
STEP="init"
LABEL="dvd"

log() { echo "[$STEP] $*" >&2; }

notify() {  # notify <priority> <title> <message>
    [ -n "$GOTIFY_URL" ] && [ -n "$GOTIFY_TOKEN" ] || return 0
    curl -fsS -m 20 -H "X-Gotify-Key: $GOTIFY_TOKEN" \
        -F "title=$2" -F "message=$3" -F "priority=$1" \
        "${GOTIFY_URL%/}/message" >/dev/null || log "gotify notify failed (ignored)"
}

unmount_disc() {
    if mountpoint -q "$MNT"; then umount "$MNT" || umount -l "$MNT" || true; fi
}

eject_disc() {
    unmount_disc
    if [ "$EJECT" = 1 ]; then eject "$DEVICE" || log "eject failed (ignored)"; fi
}

on_exit() {
    local rc=$?
    unmount_disc
    if [ "$rc" -ne 0 ]; then
        log "FAILED (exit $rc)"
        notify 8 "DVD backup failed ($(hostname -s))" \
            "Disc '$LABEL' failed during step: $STEP (exit $rc). Work dir kept. Fix the cause, then: systemctl start dvd-backup-resume (journalctl -u dvd-backup@sr0)"
    fi
}
trap on_exit EXIT

immich() {  # immich <method> <path> [curl args...]
    local method="$1" path="$2"; shift 2
    curl -fsS -m 60 -X "$method" -H "x-api-key: $IMMICH_API_KEY" -H "Accept: application/json" \
        "$@" "$IMMICH_URL/api$path"
}

# Convert → upload → album → cleanup for one work dir. Needs WORK, FP, LABEL, DATE_ISO,
# DATE_DAY (set by the disc flow, or read back from $WORK/meta.env by --resume).
process_work() {
    # ── Convert ──────────────────────────────────────────────────────────────────────
    # H.264 High + AAC in MP4 (faststart): plays natively in Immich and every browser.
    # bwdif only touches frames flagged interlaced; scale+setsar → square pixels (DVD is
    # anamorphic, e.g. 720x480 16:9 → 852x480).
    STEP="convert"
    for mkv in "$WORK"/title_*.mkv; do
        mp4="${mkv%.mkv}.mp4"
        [ -f "$mp4.done" ] && continue
        log "encoding $(basename "$mkv") ($ENCODER)"
        if [ "$ENCODER" = vaapi ]; then
            venc=(-vaapi_device "$VAAPI_DEVICE"
                  -vf 'bwdif=deint=interlaced,scale=trunc(ih*dar/2)*2:ih,setsar=1,format=nv12,hwupload'
                  -c:v h264_vaapi -profile:v high -qp "$VAAPI_QP")
        else
            venc=(-vf 'bwdif=deint=interlaced,scale=trunc(ih*dar/2)*2:ih,setsar=1'
                  -c:v libx264 -preset "$X264_PRESET" -crf "$X264_CRF" -profile:v high -pix_fmt yuv420p)
        fi
        t0=$SECONDS
        ffmpeg -nostdin -hide_banner -loglevel warning -nostats -y -i "$mkv" \
            -map 0:v:0 -map '0:a:0?' "${venc[@]}" \
            -c:a aac -b:a "$AUDIO_BITRATE" -ac 2 \
            -movflags +faststart -metadata creation_time="$DATE_ISO" -metadata title="$LABEL" \
            "$mp4.part.mp4"
        mv "$mp4.part.mp4" "$mp4"
        log "  → $(basename "$mp4") $(du -h "$mp4" | cut -f1) in $((SECONDS - t0))s"
        touch "$mp4.done"
    done

    if [ "$DRY_RUN" = 1 ]; then
        STEP="dry-run"
        log "DRY_RUN=1 — skipping upload and cleanup; output in $WORK"
        return 0
    fi

    # ── Upload ───────────────────────────────────────────────────────────────────────
    STEP="upload"
    local mkv mp4 venc t0 n name dur resp status id album_id ids_json total=0
    local -a ids=()
    for mp4 in "$WORK"/title_*.mp4; do
        n="$(basename "$mp4" .mp4)"; n="${n#title_}"
        name="${LABEL} ${DATE_DAY} t${n}.mp4"
        dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$mp4")"
        total="$(awk -v a="$total" -v b="$dur" 'BEGIN{printf "%d", a+b}')"
        log "uploading $name"
        resp="$(curl -fsS -m 3600 -X POST -H "x-api-key: $IMMICH_API_KEY" -H "Accept: application/json" \
            -F "assetData=@${mp4};filename=${name};type=video/mp4" \
            -F "filename=${name}" -F "fileCreatedAt=${DATE_ISO}" -F "fileModifiedAt=${DATE_ISO}" \
            "$IMMICH_URL/api/assets")"
        status="$(jq -r .status <<<"$resp")"
        id="$(jq -r .id <<<"$resp")"
        case "$status" in
            created|duplicate) log "  → $status $id"; ids+=("$id") ;;
            *) log "unexpected upload response: $resp"; exit 6 ;;
        esac
    done

    # ── Album ────────────────────────────────────────────────────────────────────────
    STEP="album"
    album_id="$(immich GET /albums | jq -r --arg n "$IMMICH_ALBUM" \
        '[.[] | select(.albumName == $n)][0].id // empty')"
    ids_json="$(printf '%s\n' "${ids[@]}" | jq -R . | jq -sc .)"
    if [ -z "$album_id" ]; then
        log "creating album '$IMMICH_ALBUM'"
        album_id="$(immich POST /albums -H 'Content-Type: application/json' \
            -d "$(jq -nc --arg n "$IMMICH_ALBUM" --argjson a "$ids_json" '{albumName: $n, assetIds: $a}')" \
            | jq -r .id)"
    else
        immich PUT "/albums/$album_id/assets" -H 'Content-Type: application/json' \
            -d "$(jq -nc --argjson a "$ids_json" '{ids: $a}')" >/dev/null
    fi

    # ── Record + cleanup ─────────────────────────────────────────────────────────────
    STEP="cleanup"
    echo "$FP" >>"$LEDGER"
    rm -rf --one-file-system "$WORK"
    log "done: ${#ids[@]} video(s), ${total}s → album $album_id"
    notify 5 "DVD backed up to Immich" \
        "Disc '$LABEL' ($DATE_DAY): ${#ids[@]} video(s), $((total / 60)) min → '$IMMICH_ALBUM' $IMMICH_URL/albums/$album_id"
}

# ── Resume mode (no disc needed) ─────────────────────────────────────────────────
# Finish work dirs left by a failed run once the cause is fixed (e.g. API key
# permissions), without re-inserting the disc:  dvd-backup.sh --resume
if [ "$DEVICE" = --resume ]; then
    mkdir -p "$RUN_DIR" "$STATE_DIR"
    exec 9>"$RUN_DIR/lock"
    flock 9
    found=0
    for meta in "$WORK_ROOT"/*/meta.env; do
        [ -f "$meta" ] || continue
        WORK="$(dirname "$meta")"
        [ -f "$WORK/rip.done" ] || { STEP="resume"; log "skip $WORK (rip incomplete — re-insert the disc)"; continue; }
        # shellcheck source=/dev/null
        . "$meta"
        found=1
        STEP="resume"; log "resuming disc=$LABEL fp=$FP work=$WORK"
        process_work
    done
    [ "$found" = 1 ] || { STEP="resume"; log "nothing to resume in $WORK_ROOT"; }
    exit 0
fi

# ── Wait for the disc ────────────────────────────────────────────────────────────
mkdir -p "$RUN_DIR" "$STATE_DIR" "$WORK_ROOT" "$MNT"
exec 9>"$RUN_DIR/lock"
flock 9

STEP="wait"
udevadm settle || true
for _ in $(seq 1 30); do
    if [ "$(blockdev --getsize64 "$DEVICE" 2>/dev/null || echo 0)" -gt 0 ] \
        && dd if="$DEVICE" of=/dev/null bs=2048 count=1 status=none 2>/dev/null; then
        break
    fi
    sleep 2
done

STEP="mount"
mount -o ro -t udf "$DEVICE" "$MNT" 2>/dev/null || mount -o ro "$DEVICE" "$MNT"
VIDEO_TS="$(find "$MNT" -maxdepth 1 -iname VIDEO_TS -type d | head -n1)"
[ -n "$VIDEO_TS" ] || { log "no VIDEO_TS directory — not a DVD-Video disc"; exit 3; }

LABEL="$(udevadm info -q property -n "$DEVICE" | sed -n 's/^ID_FS_LABEL=//p')"
LABEL="$(printf '%s' "${LABEL:-dvd}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^_*//;s/_*$//')"
LABEL="${LABEL:-dvd}"

# Fingerprint = IFO contents + label. Re-encodes aren't bit-identical, so Immich's own
# checksum dedupe can't catch a re-inserted disc; this ledger does.
STEP="fingerprint"
FP="$( { printf '%s\n' "$LABEL"; find "$VIDEO_TS" -maxdepth 1 -iname '*.IFO' -type f -print0 \
        | sort -z | xargs -0 cat; } | sha256sum | cut -c1-16)"
if grep -qx "$FP" "$LEDGER" 2>/dev/null; then
    log "disc $LABEL ($FP) already uploaded — ejecting"
    eject_disc
    notify 3 "DVD already backed up" "Disc '$LABEL' was already uploaded to Immich; ejected."
    exit 0
fi

# Authoring date = IFO mtime (when the disc was burned, usually close to the event).
IFO="$(find "$VIDEO_TS" -maxdepth 1 \( -iname 'VTS_01_0.IFO' -o -iname 'VIDEO_TS.IFO' \) -type f | sort | head -n1)"
EPOCH="$( [ -n "$IFO" ] && stat -c %Y "$IFO" || echo 0)"
[ "$EPOCH" -ge 946684800 ] || EPOCH="$(date +%s)"   # before 2000 → bogus, use now
DATE_ISO="$(date -u -d "@$EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)"
DATE_DAY="$(date -d "@$EPOCH" +%Y-%m-%d)"

WORK="$WORK_ROOT/$FP"
mkdir -p "$WORK"
printf 'LABEL=%q\nFP=%q\nDATE_ISO=%q\nDATE_DAY=%q\n' "$LABEL" "$FP" "$DATE_ISO" "$DATE_DAY" >"$WORK/meta.env"
log "disc=$LABEL fp=$FP date=$DATE_ISO work=$WORK"

# ── Rip (stream copy) ────────────────────────────────────────────────────────────
# Prefer ffmpeg's dvdvideo demuxer (libdvdnav: follows the IFO program chains, decrypts
# CSS via libdvdcss). Fallback for malformed IFOs: concatenate each VTS's VOBs raw.
STEP="rip"
if [ ! -f "$WORK/rip.done" ]; then
    rm -f "$WORK"/title_*.mkv
    t=1
    while dur="$(ffprobe -v error -f dvdvideo -title "$t" -show_entries format=duration \
                    -of csv=p=0 -i "$DEVICE" 2>/dev/null)" && [ -n "$dur" ]; do
        if awk -v d="$dur" -v m="$MIN_TITLE_SECONDS" 'BEGIN{exit !(d>=m)}'; then
            out="$(printf '%s/title_%02d.mkv' "$WORK" "$t")"
            log "title $t: ${dur}s → $(basename "$out")"
            ffmpeg -nostdin -hide_banner -loglevel warning -y -f dvdvideo -title "$t" -i "$DEVICE" \
                -map 0:v:0 -map '0:a?' -c copy "$out"
        else
            log "title $t: ${dur}s < ${MIN_TITLE_SECONDS}s — skipped (menu/intro)"
        fi
        t=$((t + 1))
    done

    if ! compgen -G "$WORK/title_*.mkv" >/dev/null; then
        log "dvdvideo demuxer found no usable titles — falling back to raw VOB concat"
        for vts in $(find "$VIDEO_TS" -maxdepth 1 -iname 'VTS_*_1.VOB' -printf '%f\n' \
                     | sed -E 's/^VTS_([0-9]+)_1\.VOB$/\1/I' | sort -u); do
            mapfile -t vobs < <(find "$VIDEO_TS" -maxdepth 1 -iregex ".*/VTS_${vts}_[1-9]\.VOB" | sort)
            out="$WORK/title_${vts}.mkv"
            log "VTS $vts: ${#vobs[@]} VOB(s) → $(basename "$out")"
            ffmpeg -nostdin -hide_banner -loglevel warning -y -fflags +genpts \
                -i "concat:$(IFS='|'; echo "${vobs[*]}")" -map 0:v:0 -map '0:a?' -c copy "$out"
            dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out" || echo 0)"
            if ! awk -v d="$dur" -v m="$MIN_TITLE_SECONDS" 'BEGIN{exit !(d>=m)}'; then
                log "VTS $vts: ${dur}s < ${MIN_TITLE_SECONDS}s — dropped"; rm -f "$out"; continue
            fi
            # Raw reads bypass libdvdcss: an encrypted disc yields scrambled MPEG. Refuse it.
            errs="$(ffmpeg -nostdin -v error -t 30 -i "$out" -f null - 2>&1 | wc -l)"
            if [ "$errs" -gt 20 ]; then
                log "VTS $vts decodes with $errs errors — disc is likely CSS-encrypted; raw fallback unusable"
                exit 4
            fi
        done
    fi
    compgen -G "$WORK/title_*.mkv" >/dev/null || { log "no titles ripped"; exit 5; }
    touch "$WORK/rip.done"
fi
eject_disc   # free the drive for the next disc while we convert/upload

process_work
