#!/usr/bin/env bash
# setup.sh — install or update coaster from this checkout. Safe to re-run: after a
# `git pull` it replaces only what changed, keeps /etc/coaster/env (new settings are
# appended commented-out), and restarts the watcher if needed. A backup that is running
# keeps going on the old version (files are replaced by rename, never rewritten in place).
#
#   ./setup.sh                 install / update (asks for sudo)
#   ./setup.sh --pull          git pull this checkout first, then install / update
#   ./setup.sh --configure     (re)run the questions for /etc/coaster/env
#   ./setup.sh --test-notify   send a test notification
#   ./setup.sh --uninstall [--purge]   remove coaster (--purge: also config + state)
#
# Other options: --install-deps (install missing packages), --libdvdcss (install libdvdcss
# for copy-protected DVDs — check your local law first, see README), --force (allow a
# downgrade), --yes (never ask; a first install then needs /etc/coaster/env edited by hand).
# An install under the old name (dvd-backup) is migrated: config, ledger and unfinished work
# move to /etc/coaster and /var/lib/coaster, the old units are removed.
set -euo pipefail

REPO="$(dirname "$(readlink -f "$0")")"
BIN=/usr/local/sbin/coaster
UNIT_DIR=/etc/systemd/system
UNITS=(coaster@.service coaster-resume.service coaster-watch.service)
UDEV_RULE=/etc/udev/rules.d/99-coaster.rules
CONF_DIR=/etc/coaster
ENV_FILE="$CONF_DIR/env"
STATE_DIR=/var/lib/coaster
LOG=/var/log/coaster-setup.log

PULL=0 CONFIGURE=0 TEST_NOTIFY=0 UNINSTALL=0 PURGE=0 DEPS=0 LIBDVDCSS=0 FORCE=0 YES=0
ARGS=()   # everything but --pull, for the re-exec after a pull / sudo
for a in "$@"; do
    case "$a" in
        --pull) PULL=1; continue ;;
        --configure) CONFIGURE=1 ;;
        --test-notify) TEST_NOTIFY=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --purge) PURGE=1 ;;
        --install-deps) DEPS=1 ;;
        --libdvdcss) LIBDVDCSS=1 ;;
        --force) FORCE=1 ;;
        -y|--yes) YES=1 ;;
        -h|--help) sed -n '2,/^set -e/{/^set -e/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
        *) echo "unknown option: $a (see --help)" >&2; exit 64 ;;
    esac
    ARGS+=("$a")
done

# ── git pull (as the checkout's owner, before sudo), then run the pulled setup.sh ──
if [ "$PULL" = 1 ]; then
    owner="$(stat -c %U "$REPO")"
    as_owner=()
    if [ "$(id -un)" != "$owner" ]; then
        if [ "$(id -u)" -eq 0 ]; then as_owner=(runuser -u "$owner" --); else as_owner=(sudo -u "$owner"); fi
    fi
    old="$("${as_owner[@]}" git -C "$REPO" rev-parse HEAD)"
    "${as_owner[@]}" git -C "$REPO" pull --ff-only
    new="$("${as_owner[@]}" git -C "$REPO" rev-parse HEAD)"
    if [ "$old" = "$new" ]; then echo "checkout already up to date"
    else "${as_owner[@]}" git -C "$REPO" log --oneline "$old..$new"; fi
    exec "$REPO/setup.sh" "${ARGS[@]}"
fi

if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$REPO/setup.sh" "${ARGS[@]}"; fi
umask 022
INTERACTIVE=0
if [ "$YES" = 0 ] && [ -t 0 ] && [ -t 1 ]; then INTERACTIVE=1; fi
ok="" tk=""   # set by ask()

say() { printf '%s\n' "$*"; printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; printf '%s WARNING: %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
die() { printf 'ERROR: %s\n' "$*" >&2; printf '%s ERROR: %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; exit 1; }

# ── Env file helpers (values are written single-quoted: literal for bash and systemd) ──
env_get() {  # env_get <key> — value as the service would see it ("" if unset)
    [ -f "$ENV_FILE" ] || return 0
    # shellcheck source=/dev/null
    ( set +eu; . "$ENV_FILE" >/dev/null 2>&1; printf '%s' "${!1-}" )
}
env_set() {  # env_set <key> <value> — replaces "KEY=" or "#KEY=", else appends
    local tmp
    tmp="$(mktemp "$ENV_FILE.XXXXXX")"
    K="$1" L="$1='$2'" awk '
        !done && $0 ~ ("^#?[[:space:]]*" ENVIRON["K"] "=") { print ENVIRON["L"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["L"] }' "$ENV_FILE" >"$tmp"
    chmod 0600 "$tmp"; mv -f "$tmp" "$ENV_FILE"
}
placeholder() { case "$1" in ''|changeme|*example.com*) return 0 ;; *) return 1 ;; esac; }

ask() {  # ask <var> <question> [default]
    local _a
    read -r -p "$2${3:+ [$3]}: " _a </dev/tty
    printf -v "$1" '%s' "${_a:-${3:-}}"
}
ask_value() {  # ask_value <key> <question> [suggestion] — asks until non-empty, writes it
    local cur v
    cur="$(env_get "$1")"; placeholder "$cur" && cur="${3:-}"
    while :; do
        ask v "$2" "$cur"
        case "$v" in
            '') echo "  required" ;;
            *"'"*) echo "  single quotes (') are not supported" ;;
            *) env_set "$1" "$v"; return ;;
        esac
    done
}
ask_secret() {  # ask_secret <key> <question> — hidden input, Enter keeps the current value
    local cur v
    cur="$(env_get "$1")"; placeholder "$cur" && cur=""
    while :; do
        read -r -s -p "$2${cur:+ [Enter = keep current]}: " v </dev/tty; echo
        v="${v:-$cur}"
        case "$v" in
            '') echo "  required" ;;
            *"'"*) echo "  single quotes (') are not supported" ;;
            *) env_set "$1" "$v"; return ;;
        esac
    done
}

# Paths the units must be allowed to write (ProtectSystem=strict): a WORK_ROOT outside
# STATE_DIR and, for DESTINATION=path, SAVE_DIR.
rw_paths() {
    local work save dest
    work="$(env_get WORK_ROOT)"; save="$(env_get SAVE_DIR)"; dest="$(env_get DESTINATION)"
    if [ -n "$work" ]; then case "$work" in "$STATE_DIR"|"$STATE_DIR"/*) ;; *) echo "${work%/}" ;; esac; fi
    if [ -n "$save" ] && [[ " ${dest//,/ } " == *" path "* ]]; then echo "${save%/}"; fi
}

# ── Uninstall ────────────────────────────────────────────────────────────────────
if [ "$UNINSTALL" = 1 ]; then
    say "── uninstalling coaster"
    systemctl disable --now coaster-watch.service 2>/dev/null || true
    for u in "${UNITS[@]}"; do rm -f "$UNIT_DIR/$u"; rm -rf "$UNIT_DIR/$u.d"; done
    rm -f "$UDEV_RULE" "$BIN"
    systemctl daemon-reload; udevadm control --reload || true
    if [ "$PURGE" = 1 ]; then
        if [ "$INTERACTIVE" = 1 ]; then
            ask ok "Delete $CONF_DIR (config, API keys) and $STATE_DIR (ledger, unfinished work)? (y/n)" n
            [[ "$ok" =~ ^[yY] ]] || { say "kept $CONF_DIR and $STATE_DIR"; exit 0; }
        fi
        rm -rf "$CONF_DIR" "$STATE_DIR"; say "removed $CONF_DIR and $STATE_DIR"
    else
        say "kept $CONF_DIR and $STATE_DIR (--uninstall --purge removes them)"
    fi
    exit 0
fi

# Run a coaster.sh mode with the service's env file and sandbox, so --check also
# proves the units may write SAVE_DIR / WORK_ROOT.
run_mode() {  # run_mode --check|--test-notify
    local -a props=(-p "EnvironmentFile=$ENV_FILE" -p ProtectSystem=strict -p PrivateTmp=yes)
    local p home=yes
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        props+=(-p "ReadWritePaths=\"-$p\"")
        case "$p" in /home|/home/*|/root|/root/*|/run/user|/run/user/*) home=read-only ;; *) ;; esac
    done < <(rw_paths)
    props+=(-p "ProtectHome=$home")
    if systemd-run --quiet --wait --pipe --collect true 2>/dev/null; then
        systemd-run --quiet --wait --pipe --collect "${props[@]}" "$BIN" "$1"
    else   # no D-Bus (minimal containers): run unsandboxed
        warn "systemd-run unavailable — checking without the service sandbox"
        # shellcheck disable=SC2016  # expanded by the inner bash
        env -i PATH="$PATH" bash -c 'set -a; . "$1"; set +a; exec "$2" "$3"' _ "$ENV_FILE" "$BIN" "$1"
    fi
}

if [ "$TEST_NOTIFY" = 1 ]; then
    [ -x "$BIN" ] || die "coaster is not installed yet — run ./setup.sh first"
    run_mode --test-notify; exit
fi

say "── coaster setup ($(date '+%F %T'), from $REPO)"

# ── Dependencies ─────────────────────────────────────────────────────────────────
pm=""
for c in apt-get dnf pacman zypper; do command -v "$c" >/dev/null && { pm="$c"; break; }; done
for c in systemctl udevadm journalctl systemd-run; do
    command -v "$c" >/dev/null || die "$c not found — coaster needs systemd and udev"
done
pkgs=()
for c in ffmpeg ffprobe curl jq eject flock mount umount mountpoint blockdev; do
    command -v "$c" >/dev/null && continue
    case "$c" in
        ffmpeg|ffprobe) p=ffmpeg ;;
        curl|jq) p="$c" ;;
        eject) if [ "$pm" = pacman ]; then p=util-linux; else p=eject; fi ;;
        *) p=util-linux ;;
    esac
    [[ " ${pkgs[*]} " == *" $p "* ]] || pkgs+=("$p")
done
if [ "${#pkgs[@]}" -gt 0 ]; then
    case "$pm" in
        apt-get) cmd=(apt-get install -y "${pkgs[@]}") ;;
        dnf) cmd=(dnf install -y "${pkgs[@]}") ;;   # ffmpeg: enable RPM Fusion first
        pacman) cmd=(pacman -S --needed --noconfirm "${pkgs[@]}") ;;
        zypper) cmd=(zypper install -y "${pkgs[@]}") ;;
        *) die "missing packages: ${pkgs[*]} — install them with your package manager" ;;
    esac
    if [ "$DEPS" = 1 ]; then
        say "installing: ${pkgs[*]}"; "${cmd[@]}"
    else
        die "missing packages: ${pkgs[*]} — run: sudo ${cmd[*]}  (or re-run with --install-deps)"
    fi
fi
# (not grep -q: it exits at the first match, ffmpeg gets SIGPIPE and pipefail fails the test)
ffmpeg -hide_banner -demuxers 2>/dev/null | grep -w dvdvideo >/dev/null \
    || warn "this ffmpeg has no dvdvideo demuxer (needs ffmpeg ≥ 7.0 with libdvdnav) — DVD-Video discs will fail, photo discs work"

# ── libdvdcss (opt-in) ───────────────────────────────────────────────────────────
# Only needed for CSS-encrypted commercial DVDs; libdvdread loads it when present.
# Circumventing CSS is restricted or illegal in many countries — never installed unasked.
has_dvdcss() { ldconfig -p | grep -F libdvdcss.so >/dev/null; }   # not grep -q (pipefail)
if [ "$LIBDVDCSS" = 1 ]; then
    if has_dvdcss; then
        say "libdvdcss already installed"
    else
        warn "installing libdvdcss — only do this where circumventing CSS is lawful for your use"
        case "$pm" in
            apt-get)   # libdvd-pkg (Debian contrib / Ubuntu multiverse) builds it from VideoLAN's source
                apt-get update -qq || true
                apt-cache policy libdvd-pkg | grep -E 'Candidate: [0-9]' >/dev/null \
                    || die "libdvd-pkg not available — enable 'contrib' (Debian) or 'multiverse' (Ubuntu) in your apt sources, then re-run"
                printf '%s\n' 'libdvd-pkg libdvd-pkg/build boolean true' \
                    'libdvd-pkg libdvd-pkg/post-invoke_hook-install boolean true' | debconf-set-selections
                DEBIAN_FRONTEND=noninteractive apt-get install -y libdvd-pkg
                DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive libdvd-pkg ;;
            dnf)       # RPM Fusion free + tainted
                rpm -q rpmfusion-free-release >/dev/null \
                    || die "enable RPM Fusion free first: https://rpmfusion.org/Configuration"
                rpm -q rpmfusion-free-release-tainted >/dev/null || dnf install -y rpmfusion-free-release-tainted
                dnf install -y libdvdcss ;;
            pacman) pacman -S --needed --noconfirm libdvdcss ;;
            *) die "install libdvdcss with your package manager (openSUSE: libdvdcss2 from the VideoLAN repo)" ;;
        esac
        has_dvdcss || die "libdvdcss still not found after installing"
        say "libdvdcss installed"
    fi
fi

# ── Version ──────────────────────────────────────────────────────────────────────
new_ver="$(sed -n 's/^VERSION=//p' "$REPO/coaster.sh")"
old_ver=""
[ ! -f "$BIN" ] || old_ver="$(sed -n 's/^VERSION=//p' "$BIN")"
if [ -f "$BIN" ] && [ -n "$old_ver" ] && [ "$old_ver" != "$new_ver" ] \
    && [ "$(printf '%s\n' "$old_ver" "$new_ver" | sort -V | tail -n1)" = "$old_ver" ] && [ "$FORCE" = 0 ]; then
    die "installed version $old_ver is newer than this checkout ($new_ver) — git pull, or --force to downgrade"
fi
if [ ! -f "$BIN" ]; then say "installing coaster $new_ver"
elif [ "${old_ver:-?}" = "$new_ver" ]; then say "coaster $new_ver already installed — checking files"
else say "updating coaster ${old_ver:-<0.4.0} → $new_ver"; fi
if systemctl list-units --plain --no-legend --state=active 'coaster@*' | grep -q .; then
    say "a disc backup is running — it finishes on the version it started with"
fi

# ── Migrate an install under the old name (dvd-backup) ───────────────────────────
OLD_BIN=/usr/local/sbin/dvd-backup.sh
if [ -f "$OLD_BIN" ] || [ -d /etc/dvd-backup ]; then
    if systemctl list-units --plain --no-legend --state=active 'dvd-backup@*' dvd-backup-resume.service | grep . >/dev/null; then
        die "a dvd-backup run is in progress — re-run setup.sh when it has finished"
    fi
    say "migrating the dvd-backup install to coaster"
    systemctl disable --now dvd-backup-watch.service 2>/dev/null || true
    for u in dvd-backup@.service dvd-backup-resume.service dvd-backup-watch.service; do
        rm -f "$UNIT_DIR/$u"; rm -rf "$UNIT_DIR/$u.d"
    done
    rm -f /etc/udev/rules.d/99-dvd-backup.rules "$OLD_BIN"
    systemctl daemon-reload
    if [ -d /etc/dvd-backup ] && [ ! -e "$CONF_DIR" ]; then
        mv /etc/dvd-backup "$CONF_DIR"; say "  /etc/dvd-backup → $CONF_DIR"
        sed -i 's#/var/lib/dvd-backup#/var/lib/coaster#g' "$ENV_FILE"   # e.g. an explicit WORK_ROOT
    fi
    if [ -d /var/lib/dvd-backup ] && [ ! -e "$STATE_DIR" ]; then
        mv /var/lib/dvd-backup "$STATE_DIR"; say "  /var/lib/dvd-backup → $STATE_DIR"
        # unfinished work dirs record uploaded files by absolute path
        find "$STATE_DIR" -mindepth 3 -maxdepth 3 -name uploaded.tsv -exec sed -i "s#^/var/lib/dvd-backup/#$STATE_DIR/#" {} +
    fi
    for d in /etc/dvd-backup /var/lib/dvd-backup; do
        [ ! -e "$d" ] || warn "$d left in place ($CONF_DIR / $STATE_DIR already existed) — merge or delete it by hand"
    done
fi

# ── Files ────────────────────────────────────────────────────────────────────────
CHANGED=()
put() {  # put <src> <dest> <mode> — atomic replace (rename), only when different
    if [ -f "$2" ] && cmp -s "$1" "$2"; then
        [ "$(stat -c %a "$2")" = "${3#0}" ] || chmod "$3" "$2"
        return 0
    fi
    install -D -m "$3" "$1" "$2.setup-new"
    mv -f "$2.setup-new" "$2"
    CHANGED+=("$2"); say "  wrote $2"
}
put_text() {  # put_text <dest> <mode> <content>
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$3" >"$tmp"; put "$tmp" "$1" "$2"; rm -f "$tmp"
}
# shellcheck disable=SC2053  # $1 is a glob on purpose
changed() { local f; for f in "${CHANGED[@]}"; do [[ "$f" == $1 ]] && return 0; done; return 1; }

put "$REPO/coaster.sh" "$BIN" 0755
for u in "${UNITS[@]}"; do put "$REPO/systemd/$u" "$UNIT_DIR/$u" 0644; done
put "$REPO/udev/99-coaster.rules" "$UDEV_RULE" 0644

# ── Config ───────────────────────────────────────────────────────────────────────
install -d -m 0700 "$CONF_DIR"
env_before="$(cat "$ENV_FILE" 2>/dev/null || true)"
if [ ! -f "$ENV_FILE" ]; then
    install -m 0600 "$REPO/coaster.env.example" "$ENV_FILE"
    say "  created $ENV_FILE"
    CONFIGURE=1
else
    # Settings this version knows that the env file doesn't mention yet → append them
    # commented out (defaults unchanged), so they're easy to find and enable.
    mapfile -t new_keys < <(sed -nE 's/^#?([A-Z][A-Z0-9_]*)=.*/\1/p' "$REPO/coaster.env.example" \
        | awk '!seen[$0]++' | grep -vxF -f <(sed -nE 's/^#?[[:space:]]*([A-Z][A-Z0-9_]*)=.*/\1/p' "$ENV_FILE"))
    if [ "${#new_keys[@]}" -gt 0 ]; then
        {   printf '\n# ── Added by setup.sh %s (coaster %s): new settings, see coaster.env.example ──\n' "$(date +%F)" "$new_ver"
            for k in "${new_keys[@]}"; do
                grep -m1 -E "^#?$k=" "$REPO/coaster.env.example" | sed -E 's/^#?/#/'
            done; } >>"$ENV_FILE"
        say "  new settings appended (commented out) to $ENV_FILE: ${new_keys[*]}"
    fi
fi

if [ "$CONFIGURE" = 1 ] && [ "$INTERACTIVE" = 1 ]; then
    echo
    echo "── Configure $ENV_FILE (Enter keeps the value in [brackets]) ──"
    cur="$(env_get DESTINATION)"; cur="${cur//,/ }"
    case "$cur" in path) n=2 ;; *immich*path*|*path*immich*) n=3 ;; *) n=1 ;; esac
    echo "Where should backups go?  1) Immich   2) a folder   3) both"
    while :; do
        ask n "Choice" "$n"
        case "$n" in 1) dest=immich ;; 2) dest=path ;; 3) dest="immich path" ;; *) continue ;; esac
        break
    done
    env_set DESTINATION "$dest"

    if [[ "$dest" == *immich* ]]; then
        ask_value IMMICH_URL "Immich URL (e.g. https://photos.example.org)"
        echo "Immich API key needs: asset.upload, album.read, album.create, albumAsset.create"
        ask_secret IMMICH_API_KEY "Immich API key"
        ask_value IMMICH_ALBUM "Album for DVD videos" "DVD Uploads"
        ask_value IMMICH_PHOTO_ALBUM "Album for photo discs" "Photo Discs"
    fi
    if [[ "$dest" == *path* ]]; then
        while :; do
            ask_value SAVE_DIR "Folder to save discs in (one sub-folder per disc)" "/srv/coaster"
            sd="$(env_get SAVE_DIR)"
            case "$sd" in /*) ;; *) echo "  must be an absolute path"; continue ;; esac
            case "$sd" in *'"'*|*\\*) echo "  \" and \\ are not supported in the path"; continue ;; *) ;; esac
            [ -d "$sd" ] && break
            ask ok "$sd doesn't exist — create it? (y/n)" y
            [[ "$ok" =~ ^[nN] ]] && continue
            mkdir -p "$sd"; break
        done
        own="$(env_get SAVE_OWNER)"
        if [ -z "$own" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
            own="$SUDO_USER:$(id -gn "$SUDO_USER")"
        fi
        ask own "Owner of saved files, user:group ('-' = root)" "${own:--}"
        if [ "$own" = - ]; then env_set SAVE_OWNER ""; else env_set SAVE_OWNER "$own"; fi
    fi

    cur="$(env_get NOTIFY)"
    if [ -z "$cur" ] || [ "$cur" = auto ]; then   # show what "auto" resolves to
        cur=""
        [ -z "$(env_get GOTIFY_TOKEN)" ] || cur+="gotify,"
        [ -z "$(env_get NTFY_TOPIC)" ] || cur+="ntfy,"
        [ -z "$(env_get PUSHOVER_USER)" ] || cur+="pushover,"
        [ -z "$(env_get WEBHOOK_URL)" ] || cur+="webhook,"
        cur="${cur%,}"
    fi
    echo "Notifications: none, gotify, ntfy, pushover, webhook (several: comma-separated)"
    while :; do
        ask nt "Notify via" "${cur:-none}"
        nt="${nt// /}"; bad=""
        for b in ${nt//,/ }; do case "$b" in none|gotify|ntfy|pushover|webhook) ;; *) bad="$b" ;; esac; done
        [ -z "$bad" ] && break; echo "  unknown: $bad"
    done
    env_set NOTIFY "${nt:-none}"
    for b in ${nt//,/ }; do
        case "$b" in
            gotify) ask_value GOTIFY_URL "Gotify URL"
                    ask_secret GOTIFY_TOKEN "Gotify app token" ;;
            ntfy)   ask_value NTFY_URL "ntfy server" "https://ntfy.sh"
                    ask_value NTFY_TOPIC "ntfy topic (pick something hard to guess on ntfy.sh)"
                    ask tk "ntfy access token (tk_…, empty if the topic is open)" "$(env_get NTFY_TOKEN)"
                    env_set NTFY_TOKEN "$tk" ;;
            pushover) ask_secret PUSHOVER_TOKEN "Pushover application API token"
                      ask_secret PUSHOVER_USER "Pushover user key" ;;
            webhook) ask_value WEBHOOK_URL "Webhook URL"
                     ask_value WEBHOOK_FORMAT "Payload format: json, slack (Slack/Mattermost/Rocket.Chat) or discord" "json" ;;
            *) ;;
        esac
    done
    echo
elif [ "$CONFIGURE" = 1 ]; then
    warn "not interactive — edit $ENV_FILE, then run: sudo $REPO/setup.sh"
fi
[ "$(cat "$ENV_FILE")" = "$env_before" ] || CHANGED+=("$ENV_FILE")

# ── Sandbox drop-ins (regenerated from the env file on every run) ───────────────────
conf="" home=0
work="$(env_get WORK_ROOT)"; work="${work%/}"; work="${work:-$STATE_DIR/work}"
while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in *'"'*|*\\*) die "paths with \" or \\ are not supported: $p" ;; *) ;; esac
    conf+="ReadWritePaths=\"-$p\""$'\n'
    case "$p" in /home|/home/*|/root|/root/*|/run/user|/run/user/*) home=1 ;; *) ;; esac
    [ "$p" != "$work" ] || install -d -m 0700 "$p"
    [ -d "$p" ] || warn "$p does not exist (yet) — backups fail until it does"
done < <(rw_paths)
[ "$home" = 0 ] || conf+="ProtectHome=read-only"$'\n'
for u in coaster@.service coaster-resume.service; do
    f="$UNIT_DIR/$u.d/50-paths.conf"
    if [ -n "$conf" ]; then
        put_text "$f" 0644 "# Managed by setup.sh — regenerated from $ENV_FILE on every run; don't edit.
# Paths the service may write despite ProtectSystem=strict. \"-\" = may be missing (e.g. an
# unmounted share): the run then fails cleanly and waits for coaster-resume.
[Service]
${conf%$'\n'}"
    elif [ -f "$f" ]; then
        rm -f "$f"; rmdir --ignore-fail-on-non-empty "${f%/*}"; CHANGED+=("$f"); say "  removed $f"
    fi
done

# ── Activate ─────────────────────────────────────────────────────────────────────
if changed "$UNIT_DIR/*"; then systemctl daemon-reload; fi
if changed "$UDEV_RULE"; then udevadm control --reload || warn "udev rules not reloaded (udevd not running?)"; fi
if ! systemctl is-enabled --quiet coaster-watch.service 2>/dev/null \
    || ! systemctl is-active --quiet coaster-watch.service; then
    systemctl enable --now coaster-watch.service; say "  watcher enabled"; CHANGED+=(watcher)
elif changed "$BIN" || changed "$UNIT_DIR/coaster-watch.service" || changed "$ENV_FILE"; then
    systemctl restart coaster-watch.service; say "  watcher restarted"
fi
[ "${#CHANGED[@]}" -gt 0 ] || say "  nothing changed"

# ── Check ────────────────────────────────────────────────────────────────────────
echo
say "── config check"
check_ok=1
if run_mode --check; then
    say "config OK"
    if [ "$CONFIGURE" = 1 ] && [ "$INTERACTIVE" = 1 ] && [ "$(env_get NOTIFY)" != none ]; then
        ask ok "Send a test notification? (y/n)" y
        [[ "$ok" =~ ^[nN] ]] || run_mode --test-notify || warn "test notification failed — check the settings above"
    fi
else
    warn "config check failed — fix $ENV_FILE (or run: sudo $REPO/setup.sh --configure)"
    check_ok=0
fi
pending=0
[ ! -d "$work" ] || pending="$(find "$work" -mindepth 2 -maxdepth 2 -name rip.done | wc -l)"
[ "$pending" = 0 ] || say "$pending unfinished backup(s) waiting — run: sudo systemctl start coaster-resume"
[ "$check_ok" = 1 ] || exit 1
say "done. Insert a disc and follow: journalctl -fu coaster@sr0   (log: $LOG)"
