#!/usr/bin/env bash
# coaster — back up an optical disc to Immich and/or a folder, then delete every local
# leftover.
#   • DVD-Video (VIDEO_TS): rip each title, convert to H.264/AAC MP4 → album IMMICH_ALBUM
#   • Photo/data CD or DVD: copy photos + videos off the disc, keep the originals
#     unchanged (Immich reads EXIF) → album IMMICH_PHOTO_ALBUM
#   A disc with both (e.g. a slideshow DVD plus a JPEG folder) gets both.
#   DESTINATION=path saves to SAVE_DIR/<date> <label>/ instead of (or besides) Immich.
#
# Started by udev (udev/99-coaster.rules) via coaster@<kernel-dev>.service when a
# data disc is inserted. Can also be run by hand:  sudo coaster /dev/sr0
#
# Modes: coaster <device> | --resume (finish failed runs, no disc) | --watch (alert on
# a disc so damaged the drive hangs before udev reports it) | --check (test the config) |
# --test-notify (send a test notification) | --version.
#
# Config: environment (see coaster.env.example), normally /etc/coaster/env.
# Copy-protected (CSS) DVDs need libdvdcss, which libdvdread loads if installed — see the
# README for the legal caveats. Home-made discs do not need it.
set -euo pipefail
# systemd starts us without a locale; labels/file names are UTF-8 (Japanese discs).
export LC_ALL=C.UTF-8

VERSION=0.4.2
DEVICE="${1:-/dev/sr0}"   # or --resume | --watch | --check | --test-notify | --version
[ "$DEVICE" = --version ] && { echo "coaster $VERSION"; exit 0; }

DESTINATION="${DESTINATION:-immich}"   # immich | path | "immich path"
IMMICH_URL="${IMMICH_URL:-}"
IMMICH_API_KEY="${IMMICH_API_KEY:-}"
IMMICH_ALBUM="${IMMICH_ALBUM:-DVD Uploads}"
IMMICH_PHOTO_ALBUM="${IMMICH_PHOTO_ALBUM:-Photo Discs}"
SAVE_DIR="${SAVE_DIR:-}"               # DESTINATION=path: one folder per disc in here
SAVE_OWNER="${SAVE_OWNER:-}"           # optional user[:group] for saved files
NOTIFY="${NOTIFY:-auto}"               # auto | none | gotify,ntfy,pushover,webhook
GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
PUSHOVER_TOKEN="${PUSHOVER_TOKEN:-}"
PUSHOVER_USER="${PUSHOVER_USER:-}"
PUSHOVER_API="${PUSHOVER_API:-https://api.pushover.net/1/messages.json}"   # tests override
WEBHOOK_URL="${WEBHOOK_URL:-}"
WEBHOOK_FORMAT="${WEBHOOK_FORMAT:-json}"   # json | slack (also Mattermost) | discord
WEBHOOK_HEADER="${WEBHOOK_HEADER:-}"       # optional, e.g. "Authorization: Bearer …"
WORK_ROOT="${WORK_ROOT:-/var/lib/coaster/work}"
STATE_DIR="${STATE_DIR:-/var/lib/coaster}"
RUN_DIR="${RUN_DIR:-/run/coaster}"
MIN_TITLE_SECONDS="${MIN_TITLE_SECONDS:-20}"
ENCODER="${ENCODER:-x264}"          # x264 | vaapi
X264_PRESET="${X264_PRESET:-slow}"
X264_CRF="${X264_CRF:-18}"
VAAPI_QP="${VAAPI_QP:-20}"
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
AUDIO_BITRATE="${AUDIO_BITRATE:-192k}"
DRY_RUN="${DRY_RUN:-0}"             # 1 = rip/copy + convert only; no upload, no cleanup
EJECT="${EJECT:-1}"

# Photo/video formats Immich accepts. Matched case-insensitively on photo/data discs.
MEDIA_EXT="jpg jpeg jpe jfif png gif webp avif heic heif tif tiff bmp jxl psd
  dng nef nrw cr2 cr3 crw arw sr2 srf orf rw2 raf srw pef raw rwl x3f 3fr iiq erf kdc mrw
  mp4 m4v mov qt 3gp 3gpp avi mkv mpg mpeg mp2 m2ts mts webm wmv flv mxf"

IMMICH_URL="${IMMICH_URL%/}"
SAVE_DIR="${SAVE_DIR%/}"
DESTINATION="${DESTINATION//,/ }"
MNT="$RUN_DIR/mnt"
LEDGER="$STATE_DIR/done.log"
STEP="init"
LABEL="disc"

log() { echo "[$STEP] $*" >&2; }
want() { [[ " $DESTINATION " == *" $1 "* ]]; }   # want immich|path

# Notification backends: NOTIFY lists them; "auto" = every backend that is configured.
NOTIFY_TO=()
for b in ${NOTIFY//,/ }; do
    case "$b" in
        auto)
            if [ -n "$GOTIFY_URL" ] && [ -n "$GOTIFY_TOKEN" ]; then NOTIFY_TO+=(gotify); fi
            if [ -n "$NTFY_TOPIC" ]; then NOTIFY_TO+=(ntfy); fi
            if [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then NOTIFY_TO+=(pushover); fi
            if [ -n "$WEBHOOK_URL" ]; then NOTIFY_TO+=(webhook); fi ;;
        none) ;;
        *) NOTIFY_TO+=("$b") ;;
    esac
done

# Secrets (API key, tokens, webhook URL) go to curl as a config on a pipe, never as
# arguments: arguments are readable by every local user (ps, /proc/*/cmdline).
curl_cfg() {  # curl_cfg <option> <value> [<option> <value>...] — curl config lines
    local v
    while [ "$#" -ge 2 ]; do
        v="${2//\\/\\\\}"; v="${v//\"/\\\"}"
        printf '%s = "%s"\n' "$1" "$v"; shift 2
    done
}

# One message to every backend; a failing backend is logged and ignored. Priority uses
# Gotify's 0–10 scale (3 info, 5 success, 8 failure) and is mapped for the others.
NOTIFY_FAILED=0
notify() {  # notify <priority> <title> <message>
    local p="$1" title="$2" msg="$3" b rc host
    local -a cfg
    host="$(hostname -s)"
    for b in "${NOTIFY_TO[@]}"; do
        rc=0
        case "$b" in
            gotify)
                curl -fsS -m 20 -K <(curl_cfg header "X-Gotify-Key: $GOTIFY_TOKEN") --form-string "title=$title" \
                    --form-string "message=$msg" -F "priority=$p" "${GOTIFY_URL%/}/message" >/dev/null || rc=$? ;;
            ntfy)   # JSON publish: UTF-8 titles (headers would need RFC 2047)
                cfg=(header 'Content-Type: application/json')
                [ -z "$NTFY_TOKEN" ] || cfg+=(header "Authorization: Bearer $NTFY_TOKEN")
                jq -nc --arg t "$NTFY_TOPIC" --arg ti "$title" --arg m "$msg" \
                        --argjson p "$( ((p >= 8)) && echo 4 || { ((p >= 5)) && echo 3 || echo 2; })" \
                        --arg tag "$( ((p >= 8)) && echo warning || echo dvd)" \
                        '{topic: $t, title: $ti, message: $m, priority: $p, tags: [$tag]}' \
                    | curl -fsS -m 20 -K <(curl_cfg "${cfg[@]}") --data-binary @- "${NTFY_URL%/}" >/dev/null || rc=$? ;;
            pushover)
                curl -fsS -m 20 -K <(curl_cfg form-string "token=$PUSHOVER_TOKEN" form-string "user=$PUSHOVER_USER") \
                    --form-string "title=$title" --form-string "message=$msg" \
                    -F "priority=$( ((p >= 8)) && echo 1 || { ((p >= 5)) && echo 0 || echo -1; })" \
                    "$PUSHOVER_API" >/dev/null || rc=$? ;;
            webhook)   # the URL itself is a secret for Slack/Discord/Mattermost
                cfg=(url "$WEBHOOK_URL" header 'Content-Type: application/json')
                [ -z "$WEBHOOK_HEADER" ] || cfg+=(header "$WEBHOOK_HEADER")
                jq -nc --arg f "$WEBHOOK_FORMAT" --arg ti "$title" --arg m "$msg" --argjson p "$p" --arg h "$host" '
                        if $f == "slack" then {text: "\($ti)\n\($m)"}
                        elif $f == "discord" then {content: "**\($ti)**\n\($m)"}
                        else {title: $ti, message: $m, priority: $p, host: $h} end' \
                    | curl -fsS -m 20 -K <(curl_cfg "${cfg[@]}") --data-binary @- >/dev/null || rc=$? ;;
            *) log "unknown notification backend '$b' (ignored)"; rc=1 ;;
        esac
        if [ "$rc" -ne 0 ]; then log "$b notify failed (ignored)"; NOTIFY_FAILED=1; fi
    done
}

# Config problems, one per line (empty = OK).
config_errors() {
    local d b c
    local -a progs=(ffmpeg ffprobe curl jq flock)
    # the drive tools aren't needed to finish work dirs without a disc (--resume)
    [ "$DEVICE" = --resume ] || progs+=(eject mountpoint blockdev udevadm)
    for c in "${progs[@]}"; do
        command -v "$c" >/dev/null || echo "missing program: $c (install it, e.g. via ./setup.sh)"
    done
    [ -n "$DESTINATION" ] || echo "DESTINATION is empty (immich, path or both)"
    for d in $DESTINATION; do
        case "$d" in immich|path) ;; *) echo "DESTINATION: unknown '$d' (immich, path)" ;; esac
    done
    if want immich; then
        [ -n "$IMMICH_URL" ] || echo "IMMICH_URL not set"
        [ -n "$IMMICH_API_KEY" ] || echo "IMMICH_API_KEY not set"
    fi
    if want path; then [ -n "$SAVE_DIR" ] || echo "SAVE_DIR not set (DESTINATION includes path)"; fi
    for b in "${NOTIFY_TO[@]}"; do
        case "$b" in
            gotify) [ -n "$GOTIFY_URL" ] && [ -n "$GOTIFY_TOKEN" ] || echo "NOTIFY=gotify needs GOTIFY_URL and GOTIFY_TOKEN" ;;
            ntfy) [ -n "$NTFY_TOPIC" ] || echo "NOTIFY=ntfy needs NTFY_TOPIC" ;;
            pushover) [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ] || echo "NOTIFY=pushover needs PUSHOVER_TOKEN and PUSHOVER_USER" ;;
            webhook) [ -n "$WEBHOOK_URL" ] || echo "NOTIFY=webhook needs WEBHOOK_URL" ;;
            *) echo "NOTIFY: unknown backend '$b' (gotify, ntfy, pushover, webhook)" ;;
        esac
    done
    case "$WEBHOOK_FORMAT" in json|slack|discord) ;; *) echo "WEBHOOK_FORMAT: unknown '$WEBHOOK_FORMAT' (json, slack, discord)" ;; esac
}

unmount_disc() {
    if mountpoint -q "$MNT"; then umount "$MNT" || umount -l "$MNT" || true; fi
}

eject_disc() {
    unmount_disc
    if [ "$EJECT" = 1 ]; then timeout 60 eject "$DEVICE" || log "eject failed (ignored)"; fi
}

FAIL_DETAIL=""
WORK=""
case "$DEVICE" in --*) UNIT="coaster${DEVICE/--/-}" ;; *) UNIT="coaster@${DEVICE##*/}" ;; esac
on_exit() {
    local rc=$?
    case "$DEVICE" in --check|--test-notify) return ;; *) ;; esac
    unmount_disc
    # Failed while reading the disc (before the rip finished): the disc is unreadable —
    # eject it and drop the partial copy; there is nothing to resume.
    if [ "$rc" -ne 0 ] && [[ "$STEP" =~ ^(wait|mount|fingerprint|rip)$ ]] \
        && { [ -z "$WORK" ] || [ ! -f "$WORK/rip.done" ]; }; then
        log "disc unreadable (step $STEP, exit $rc) — ejecting"
        [ "$EJECT" = 1 ] && { timeout 60 eject "$DEVICE" || log "eject failed"; }
        [ -n "$WORK" ] && [ "$DRY_RUN" != 1 ] && rm -rf --one-file-system "$WORK"
        notify 8 "Disc can't be read ($(hostname -s))" \
            "Disc '$LABEL' could not be read (step: $STEP) and was ejected. Clean it and try again, or try another drive. Details: journalctl -u $UNIT"
        return
    fi
    if [ "$rc" -ne 0 ]; then
        log "FAILED (exit $rc)"
        notify 8 "Disc backup failed ($(hostname -s))" \
            "Disc '$LABEL' failed during step: $STEP (exit $rc).${FAIL_DETAIL:+ $FAIL_DETAIL} Work dir kept. Fix the cause, then: systemctl start coaster-resume (journalctl -u $UNIT)"
    fi
}
trap on_exit EXIT

# Immich API call; on HTTP ≥ 400 logs Immich's error message (e.g. "Missing required
# permission: albumAsset.create") and puts it in the failure notification.
immich() {  # immich <method> <path> [curl args...]
    local method="$1" path="$2" out code body; shift 2
    out="$(curl -sS -m 3600 -w '\n%{http_code}' -X "$method" -K <(curl_cfg header "x-api-key: $IMMICH_API_KEY") \
        -H "Accept: application/json" "$@" "$IMMICH_URL/api$path")" \
        || { FAIL_DETAIL="Immich $method $path: no connection to $IMMICH_URL"; log "$FAIL_DETAIL"; return 7; }
    code="${out##*$'\n'}"; body="${out%$'\n'*}"
    if [ "$code" -ge 400 ]; then
        FAIL_DETAIL="Immich $method $path → HTTP $code: $(jq -r '.message // .' <<<"$body" 2>/dev/null | head -c 200)"
        log "$FAIL_DETAIL"
        return 22
    fi
    printf '%s' "$body"
}

# Upload one file; idempotent across retries via $WORK/uploaded.tsv (path → asset id).
# Immich itself answers "duplicate" for byte-identical files.
UPLOADED_IDS=()
upload() {  # upload <file> <filename> <ISO date>
    local f="$1" name="$2" date="$3" resp status id
    id=""
    [ -f "$WORK/uploaded.tsv" ] && id="$(awk -F'\t' -v p="$f" '$1 == p {print $2; exit}' "$WORK/uploaded.tsv")"
    if [ -z "$id" ]; then
        resp="$(immich POST /assets -F "assetData=@${f};filename=${name}" -F "filename=${name}" \
            -F "fileCreatedAt=${date}" -F "fileModifiedAt=${date}")"
        status="$(jq -r .status <<<"$resp")"; id="$(jq -r .id <<<"$resp")"
        case "$status" in
            created|duplicate) log "  $name → $status $id" ;;
            *) FAIL_DETAIL="unexpected upload response: $resp"; log "$FAIL_DETAIL"; return 6 ;;
        esac
        printf '%s\t%s\n' "$f" "$id" >>"$WORK/uploaded.tsv"
    fi
    UPLOADED_IDS+=("$id")
}

# Add asset ids to an album by name, creating it if missing.
album_add() {  # album_add <album name> <id>...
    local name="$1" album_id i chunk; shift
    album_id="$(immich GET /albums | jq -r --arg n "$name" '[.[] | select(.albumName == $n)][0].id // empty')"
    if [ -z "$album_id" ]; then
        log "creating album '$name'"
        album_id="$(immich POST /albums -H 'Content-Type: application/json' \
            -d "$(jq -nc --arg n "$name" '{albumName: $n}')" | jq -r .id)"
    fi
    for ((i = 0; i < $#; i += 500)); do
        chunk="$(printf '%s\n' "${@:i+1:500}" | jq -R . | jq -sc '{ids: .}')"
        immich PUT "/albums/$album_id/assets" -H 'Content-Type: application/json' -d "$chunk" >/dev/null
    done
    ALBUM_URL="$IMMICH_URL/albums/$album_id"
}

# DESTINATION=path: the disc's folder, "SAVE_DIR/<date> <label>" (" (2)", … if taken by
# another disc). Chosen once and remembered in $WORK/save_dir, so a resume reuses it.
# SAVE_DIR itself must exist — creating it could write onto an unmounted mount point.
save_dir() {
    local base i=2
    if [ -f "$WORK/save_dir" ]; then SAVE_TO="$(cat "$WORK/save_dir")"; return; fi
    if [ ! -d "$SAVE_DIR" ]; then
        FAIL_DETAIL="SAVE_DIR $SAVE_DIR does not exist (not mounted?)"; log "$FAIL_DETAIL"; return 3
    fi
    base="$SAVE_DIR/$DATE_DAY $LABEL"; SAVE_TO="$base"
    while [ -e "$SAVE_TO" ]; do SAVE_TO="$base ($i)"; i=$((i + 1)); done
    mkdir "$SAVE_TO"
    printf '%s\n' "$SAVE_TO" >"$WORK/save_dir"
}

# Copy one file into the disc's folder. Files appear under their final name only when
# complete (.part + rename), so an existing one was saved by an earlier, interrupted run.
save_file() {  # save_file <file> <dest> [ISO date for mtime]
    local f="$1" dst="$2"
    [ -f "$dst" ] && return 0
    mkdir -p "$(dirname "$dst")"
    cp --reflink=auto --preserve=timestamps "$f" "$dst.part"
    [ -z "${3:-}" ] || touch -d "$3" "$dst.part"
    mv "$dst.part" "$dst"
    log "  saved ${dst#"$SAVE_TO/"}"
}

# Convert → save/upload → album → cleanup for one work dir. Needs WORK, FP, LABEL,
# DATE_ISO, DATE_DAY (set by the disc flow, or read back from $WORK/meta.env by --resume).
process_work() {
    local mkv mp4 venc t0 n f summary="" vids=0 photos=0 total=0 i
    local -a vid_src=() vid_name=() pho_src=() video_ids=()

    # ── Convert DVD-Video titles ─────────────────────────────────────────────────
    # H.264 High + AAC in MP4 (faststart): plays natively in Immich and every browser.
    # bwdif only touches frames flagged interlaced; scale+setsar → square pixels (DVD is
    # anamorphic, e.g. 720x480 16:9 → 852x480).
    STEP="convert"
    for mkv in "$WORK"/title_*.mkv; do
        [ -f "$mkv" ] || continue
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

    for mp4 in "$WORK"/title_*.mp4; do
        [ -f "$mp4" ] || continue
        n="$(basename "$mp4" .mp4)"; n="${n#title_}"
        total="$(awk -v a="$total" -v b="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$mp4")" \
            'BEGIN{printf "%d", a+b}')"
        vid_src+=("$mp4"); vid_name+=("${LABEL} ${DATE_DAY} t${n}.mp4")
    done
    [ ! -d "$WORK/files" ] || mapfile -d '' pho_src < <(find "$WORK/files" -type f -print0 | sort -z)
    vids=${#vid_src[@]}; photos=${#pho_src[@]}

    # ── Save to SAVE_DIR/<date> <label>/ (videos on top, data-disc files in their
    #    folder structure from the disc, mtimes kept) ───────────────────────────────
    if want path; then
        STEP="save"
        save_dir
        for i in "${!vid_src[@]}"; do save_file "${vid_src[i]}" "$SAVE_TO/${vid_name[i]}" "$DATE_ISO"; done
        for f in "${pho_src[@]}"; do save_file "$f" "$SAVE_TO/${f#"$WORK/files/"}"; done
        [ -z "$SAVE_OWNER" ] || chown -R "$SAVE_OWNER" "$SAVE_TO"
        summary="$( [ "$vids" -eq 0 ] || printf '%s video(s), %s min, ' "$vids" "$((total / 60))"
                    [ "$photos" -eq 0 ] || printf '%s photo/video file(s), ' "$photos")"
        summary="${summary%, } → $SAVE_TO"
    fi

    if want immich; then
        # ── Videos → IMMICH_ALBUM ────────────────────────────────────────────────
        STEP="upload"
        UPLOADED_IDS=()
        for i in "${!vid_src[@]}"; do upload "${vid_src[i]}" "${vid_name[i]}" "$DATE_ISO"; done
        video_ids=("${UPLOADED_IDS[@]}")
        if [ "$vids" -gt 0 ]; then
            STEP="album"; album_add "$IMMICH_ALBUM" "${video_ids[@]}"
            summary="${summary:+$summary; }$vids video(s), $((total / 60)) min → '$IMMICH_ALBUM' $ALBUM_URL"
        fi

        # ── Photos/videos copied off a data disc → IMMICH_PHOTO_ALBUM (originals) ─
        # Date = file mtime on the disc; Immich prefers EXIF DateTimeOriginal when present.
        STEP="upload"
        UPLOADED_IDS=()
        for f in "${pho_src[@]}"; do
            upload "$f" "$(basename "$f")" "$(date -u -d "@$(stat -c %Y "$f")" +%Y-%m-%dT%H:%M:%S.000Z)"
        done
        if [ "$photos" -gt 0 ]; then
            STEP="album"; album_add "$IMMICH_PHOTO_ALBUM" "${UPLOADED_IDS[@]}"
            summary="${summary:+$summary; }$photos photo/video file(s) → '$IMMICH_PHOTO_ALBUM' $ALBUM_URL"
        fi
    fi

    # ── Record + cleanup ─────────────────────────────────────────────────────────
    STEP="cleanup"
    echo "$FP" >>"$LEDGER"
    rm -rf --one-file-system "$WORK"
    log "done: $summary"
    notify 5 "Disc backed up" "Disc '$LABEL' ($DATE_DAY): $summary"
}

# ── Watch mode (coaster-watch.service) ────────────────────────────────────────
# A badly damaged disc can hang the drive before this script ever starts: udev's own
# filesystem probe blocks, the drive times out, resets, and the kernel takes it offline,
# so no "disc inserted" event ever arrives. Follow the kernel log for those signs and
# alert + try to eject. Signs: SCSI read timeouts / device offline on sr*, or a USB reset
# of the port an optical drive hangs off (sometimes the only trace — the drive then just
# reports "No medium"). Ignores the instant "Illegal mode for this track" read error
# every healthy CD-R gives at its run-out blocks.
optical_usb_ports() {  # "sr0 2-3" per USB-attached optical drive
    local d port
    for d in /sys/block/sr*; do
        [ -e "$d" ] || continue
        port="$(readlink -f "$d/device" | grep -oE '/usb[0-9]+/[0-9]+-[0-9.]+/' | cut -d/ -f3)"
        [ -n "$port" ] && echo "${d##*/} $port"
    done
}
if [ "$DEVICE" = --watch ]; then
    STEP="watch"
    last=-600   # SECONDS starts at 0: allow an alert right after (re)start
    journalctl -k -f -n 0 -o cat | while IFS= read -r line; do
        dev=""
        case "$line" in
            *"sr"[0-9]*"DID_TIME_OUT"*|*"device offline error, dev sr"[0-9]*)
                dev="/dev/$(grep -oE 'sr[0-9]+' <<<"$line" | head -n1)" ;;
            "usb "*": reset "*)
                port="$(cut -d' ' -f2 <<<"$line")"; port="${port%:}"
                dev="$(optical_usb_ports | awk -v p="$port" '$2 == p {print "/dev/" $1; exit}')" ;;
            *) ;;
        esac
        [ -n "$dev" ] || continue
        [ $((SECONDS - last)) -ge 600 ] || continue   # one alert per incident
        last=$SECONDS
        log "drive error on $dev: $line"
        if timeout 60 eject "$dev" 2>/dev/null; then
            msg="The disc in $dev can't be read (drive timed out / reset) and was ejected. Clean it and try again, or try another drive."
        else
            msg="The disc in $dev can't be read (drive timed out / reset). Eject failed — press the drive's eject button or re-plug its USB cable."
        fi
        log "$msg"
        notify 8 "Disc can't be read ($(hostname -s))" "$msg"
    done
    exit 0
fi

# ── Test modes (setup.sh runs these) ─────────────────────────────────────────────
if [ "$DEVICE" = --test-notify ]; then
    STEP="test-notify"
    [ "${#NOTIFY_TO[@]}" -gt 0 ] || { log "no notification backend configured (NOTIFY=$NOTIFY)"; exit 1; }
    notify 5 "coaster test ($(hostname -s))" "Test notification from coaster $VERSION via ${NOTIFY_TO[*]}."
    [ "$NOTIFY_FAILED" = 0 ] && log "sent via ${NOTIFY_TO[*]}"
    exit "$NOTIFY_FAILED"
fi
if [ "$DEVICE" = --check ]; then
    STEP="check"
    problems="$(config_errors)"
    [ -z "$problems" ] || { while IFS= read -r p; do log "config: $p"; done <<<"$problems"; exit 2; }
    ok=1
    if want immich; then
        if albums="$(immich GET /albums)"; then
            log "Immich OK: $IMMICH_URL ($(jq length <<<"$albums") albums visible to the key)"
        else
            log "Immich check failed (see above)"; ok=0
        fi
    fi
    if want path; then
        if [ -d "$SAVE_DIR" ] && t="$(mktemp -p "$SAVE_DIR" .coaster-check.XXXXXX)" && rm -f "$t"; then
            log "SAVE_DIR OK: $SAVE_DIR (writable, $(df -h --output=avail "$SAVE_DIR" | tail -n1 | tr -d ' ') free)"
        else
            log "SAVE_DIR not writable or missing: $SAVE_DIR"; ok=0
        fi
    fi
    log "destination: $DESTINATION; notifications: ${NOTIFY_TO[*]:-none}"
    exit $((1 - ok))
fi

problems="$(config_errors)"
if [ -n "$problems" ]; then
    while IFS= read -r p; do log "config: $p"; done <<<"$problems"
    FAIL_DETAIL="Config error: $(tr '\n' ';' <<<"$problems") (/etc/coaster/env)"
    exit 2
fi

# ── Resume mode (no disc needed) ─────────────────────────────────────────────────
# Finish work dirs left by a failed run once the cause is fixed (e.g. API key
# permissions), without re-inserting the disc:  coaster --resume
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
        UPLOADED_IDS=()
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
ready=0
for _ in $(seq 1 30); do
    if [ "$(timeout 30 blockdev --getsize64 "$DEVICE" 2>/dev/null || echo 0)" -gt 0 ] \
        && timeout 30 dd if="$DEVICE" of=/dev/null bs=2048 count=1 status=none 2>/dev/null; then
        ready=1; break
    fi
    sleep 2
done
[ "$ready" = 1 ] || { log "disc did not become readable"; exit 7; }

# CD-Rs end in unreadable run-out blocks, and the UDF driver reads the disc's last block,
# so mount CDs as ISO9660 (superblock near the start only).
props="$(udevadm info -q property -n "$DEVICE")"
IS_CD=0
grep -qE '^ID_CDROM_MEDIA_CD(_R|_RW)?=1$' <<<"$props" && IS_CD=1
FSTYPE="$(sed -n 's/^ID_FS_TYPE=//p' <<<"$props")"

STEP="mount"
if [ "$IS_CD" = 1 ] || [ "$FSTYPE" = iso9660 ]; then
    mount -o ro -t iso9660 "$DEVICE" "$MNT" 2>/dev/null || mount -o ro "$DEVICE" "$MNT"
else
    mount -o ro -t udf "$DEVICE" "$MNT" 2>/dev/null || mount -o ro "$DEVICE" "$MNT"
fi

LABEL="$(sed -n 's/^ID_FS_LABEL=//p' <<<"$props")"
if [ -z "$LABEL" ]; then   # ISO9660 PVD (block 16): volume identifier at byte 40, 32 chars
    LABEL="$(dd if="$DEVICE" bs=2048 skip=16 count=1 status=none 2>/dev/null | dd bs=1 skip=40 count=32 status=none | tr -d '\0' | sed 's/ *$//')"
fi
# Keep Unicode (Japanese school/photographer labels); only make it filename-safe.
LABEL="$(printf '%s' "${LABEL:-disc}" | sed 's#[/\\[:cntrl:]]#_#g; s/^[_ ]*//; s/[_ ]*$//')"
LABEL="${LABEL:-disc}"

VIDEO_TS="$(find "$MNT" -maxdepth 1 -iname VIDEO_TS -type d | head -n1)"
# Media files outside the DVD-Video structure (VIDEO_TS/AUDIO_TS hold VOBs, not files to keep).
ext_re="$(tr -s ' \n' '|' <<<"$MEDIA_EXT" | sed 's/^|//;s/|$//')"
mapfile -d '' MEDIA_FILES < <(find "$MNT" \( -ipath "$MNT/VIDEO_TS" -o -ipath "$MNT/AUDIO_TS" \) -prune \
    -o -type f -regextype posix-extended -iregex ".*\.($ext_re)" -print0 | sort -z)
log "label=$LABEL cd=$IS_CD fs=${FSTYPE:-?} video_ts=${VIDEO_TS:+yes} media_files=${#MEDIA_FILES[@]}"

if [ -z "$VIDEO_TS" ] && [ "${#MEDIA_FILES[@]}" -eq 0 ]; then
    log "no DVD-Video and no photos/videos on disc — nothing to import, ejecting"
    eject_disc
    notify 5 "Disc not imported" "Disc '$LABEL' has no DVD-Video and no photos/videos; ejected."
    exit 0
fi

# Fingerprint → ledger skips discs already backed up without a rip + encode (Immich's
# checksum dedupe only catches a repeat after that work). School discs from the same
# authoring tool share a label and can have near-identical IFOs, so besides label + IFO
# contents hash every file's name, size and mtime (directory metadata only — no VOB
# reads, works on CSS discs).
STEP="fingerprint"
FP="$( { printf 'v2 %s\n' "$LABEL"
        [ -z "$VIDEO_TS" ] || find "$VIDEO_TS" -maxdepth 1 -iname '*.IFO' -type f -print0 | sort -z | xargs -0 -r cat
        find "$MNT" -type f -printf '%P %s %T@\n' | LC_ALL=C sort; } | sha256sum | cut -c1-16)"
if grep -qxF "$FP" "$LEDGER" 2>/dev/null; then
    log "disc $LABEL ($FP) already backed up — ejecting"
    eject_disc
    notify 3 "Disc already backed up" "Disc '$LABEL' was already backed up; ejected."
    exit 0
fi

# Disc date: DVD-Video → IFO mtime (authoring date, usually close to the event);
# data disc → newest file mtime (≈ when it was burned). Photos keep their own dates.
if [ -n "$VIDEO_TS" ]; then
    IFO="$(find "$VIDEO_TS" -maxdepth 1 \( -iname 'VTS_01_0.IFO' -o -iname 'VIDEO_TS.IFO' \) -type f | sort | head -n1)"
    EPOCH="$( [ -n "$IFO" ] && stat -c %Y "$IFO" || echo 0)"
else
    EPOCH="$(find "$MNT" -type f -printf '%T@\n' | sort -n | tail -n1 | cut -d. -f1)"
fi
[ "${EPOCH:-0}" -ge 946684800 ] || EPOCH="$(date +%s)"   # before 2000 → bogus, use now
DATE_ISO="$(date -u -d "@$EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)"
DATE_DAY="$(date -d "@$EPOCH" +%Y-%m-%d)"

WORK="$WORK_ROOT/$FP"
mkdir -p "$WORK"
printf 'LABEL=%q\nFP=%q\nDATE_ISO=%q\nDATE_DAY=%q\n' "$LABEL" "$FP" "$DATE_ISO" "$DATE_DAY" >"$WORK/meta.env"
log "disc=$LABEL fp=$FP date=$DATE_ISO work=$WORK"

STEP="rip"
if [ ! -f "$WORK/rip.done" ]; then
    # ── DVD-Video titles (stream copy) ───────────────────────────────────────────
    # Prefer ffmpeg's dvdvideo demuxer (libdvdnav: follows the IFO program chains,
    # decrypts CSS via libdvdcss). Fallback for malformed IFOs: concatenate VOBs raw.
    if [ -n "$VIDEO_TS" ]; then
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
        if ! compgen -G "$WORK/title_*.mkv" >/dev/null && [ "${#MEDIA_FILES[@]}" -eq 0 ]; then
            log "no titles ripped"; exit 5
        fi
    fi

    # ── Photos/videos on a data disc (copied as-is, mtimes kept) ─────────────────
    if [ "${#MEDIA_FILES[@]}" -gt 0 ]; then
        rm -rf "$WORK/files"
        log "copying ${#MEDIA_FILES[@]} photo/video file(s)"
        (cd "$MNT" && printf '%s\0' "${MEDIA_FILES[@]#"$MNT/"}" | xargs -0 cp --parents -p -t "$WORK/files" 2>/dev/null) \
            || { mkdir -p "$WORK/files"; (cd "$MNT" && printf '%s\0' "${MEDIA_FILES[@]#"$MNT/"}" | xargs -0 cp --parents -p -t "$WORK/files"); }
        log "  → $(du -sh "$WORK/files" | cut -f1)"
    fi
    touch "$WORK/rip.done"
fi
eject_disc   # free the drive for the next disc while we convert/upload

process_work
