#!/usr/bin/env bash
# Smoke tests: run coaster.sh's --check / --test-notify / --resume modes against a mock
# Immich + notification server. No disc, no root, no network. Needs bash, curl, jq, ffmpeg
# (ffprobe), python3.   Usage: tests/smoke.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/coaster.sh"
T="$(mktemp -d)"
PORT="${PORT:-18765}"
M="http://127.0.0.1:$PORT"
LOG="$T/requests.jsonl"
fails=0

python3 -I "$REPO/tests/mock_server.py" "$PORT" "$LOG" &
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 50); do curl -s "$M/ping" >/dev/null && break; sleep 0.1; done

pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
check() {  # check <description> <command...>
    local d="$1"; shift
    if "$@"; then pass "$d"; else fail "$d"; fi
}
requests() { jq -c "select($1)" "$LOG"; }   # requests <jq filter> — matching logged requests

# Minimal environment, like the systemd unit gives it.
run() {  # run <mode> [VAR=value...] — output in $T/out, exit code in $rc
    local mode="$1"; shift
    rc=0
    env -i PATH="$PATH" WORK_ROOT="$T/work" STATE_DIR="$T/state" RUN_DIR="$T/run" \
        IMMICH_URL="$M/" IMMICH_API_KEY=key NOTIFY=none "$@" bash "$BIN" "$mode" >"$T/out" 2>&1 || rc=$?
}

# A work dir as a disc run leaves it after ripping: one DVD title (already converted) plus
# data-disc files; the label is UTF-8 like on Japanese school discs.
make_work() {  # make_work <fingerprint>
    local w="$T/work/$1"
    mkdir -p "$w/files/DCIM/100"
    ffmpeg -nostdin -v error -f lavfi -i testsrc=d=2:s=160x120 -f lavfi -i sine=d=2 -shortest "$w/title_01.mp4"
    echo one >"$w/files/DCIM/100/IMG_0001.JPG"
    echo two >"$w/files/DCIM/100/IMG_0002.JPG"
    touch -d 2010-05-01T12:00:00Z "$w/files/DCIM/100/IMG_0001.JPG"
    touch "$w/rip.done"
    printf 'LABEL=%q\nFP=%q\nDATE_ISO=%q\nDATE_DAY=%q\n' "運動会 2024" "$1" \
        2024-06-01T01:00:00.000Z 2024-06-01 >"$w/meta.env"
}

echo "── version / config"
run --version
check "--version prints the version" grep -qE '^coaster [0-9]+\.[0-9]+\.[0-9]+$' "$T/out"
run --check DESTINATION=path NOTIFY=pushover,carrier-pigeon
check "--check rejects a bad config (exit 2)" test "$rc" = 2
check "  names the missing SAVE_DIR" grep -q 'SAVE_DIR not set' "$T/out"
check "  names the incomplete backend" grep -q 'NOTIFY=pushover needs' "$T/out"
check "  names the unknown backend" grep -q "unknown backend 'carrier-pigeon'" "$T/out"
mkdir -p "$T/save"
run --check DESTINATION="immich path" SAVE_DIR="$T/save"
check "--check passes with Immich + SAVE_DIR" test "$rc" = 0
: >"$LOG"
run --check IMMICH_API_KEY='k"e\y'
check "API key with quotes/backslash reaches Immich intact (curl config quoting)" \
    test -n "$(requests '.path == "/api/albums" and .auth == "k\"e\\y"')"
run --check IMMICH_URL=http://127.0.0.1:1
check "--check fails when Immich is unreachable" test "$rc" = 1

echo "── notifications"
: >"$LOG"
run --test-notify NOTIFY=gotify,ntfy,pushover,webhook GOTIFY_URL="$M" GOTIFY_TOKEN=gt \
    NTFY_URL="$M/" NTFY_TOPIC=discs NTFY_TOKEN=tk_x PUSHOVER_API="$M/1/messages.json" \
    PUSHOVER_TOKEN=pt PUSHOVER_USER=pu WEBHOOK_URL="$M/hook" WEBHOOK_FORMAT=discord \
    WEBHOOK_HEADER="Authorization: Bearer wh"
check "--test-notify succeeds with all four backends" test "$rc" = 0
check "  gotify: token header, form fields" \
    test -n "$(requests '.path == "/message" and .auth == "gt" and (.body | contains("name=\"title\""))')"
check "  ntfy: JSON publish with topic + bearer token" \
    test -n "$(requests '.path == "/" and .auth == "Bearer tk_x" and (.body | fromjson | .topic == "discs" and .priority == 3)')"
check "  pushover: token + user" \
    test -n "$(requests '.path == "/1/messages.json" and (.body | contains("pt") and contains("pu"))')"
check "  webhook: discord payload + extra header" \
    test -n "$(requests '.path == "/hook" and .auth == "Bearer wh" and (.body | fromjson | has("content"))')"
run --test-notify NOTIFY=webhook WEBHOOK_URL="$M/fail"
check "--test-notify reports a failing backend (exit 1)" test "$rc" = 1
run --test-notify NOTIFY=auto
check "--test-notify with nothing configured exits 1" test "$rc" = 1

echo "── resume: Immich + folder"
: >"$LOG"
make_work fp1
mkdir -p "$T/save/2024-06-01 運動会 2024"   # taken by another disc → " (2)"
run --resume DESTINATION=immich,path SAVE_DIR="$T/save" NOTIFY=webhook WEBHOOK_URL="$M/hook"
d="$T/save/2024-06-01 運動会 2024 (2)"
check "resume exits 0" test "$rc" = 0
check "  video saved with the disc date as mtime" \
    test "$(date -u -r "$d/運動会 2024 2024-06-01 t01.mp4" +%F)" = 2024-06-01
check "  photo saved in the disc's folder structure, mtime kept" \
    test "$(date -u -r "$d/DCIM/100/IMG_0001.JPG" +%F)" = 2010-05-01
check "  no .part files left" test -z "$(find "$T/save" -name '*.part')"
check "  3 assets uploaded" test "$(requests '.path == "/api/assets"' | wc -l)" = 3
check "  video upload uses the label name" \
    test -n "$(requests '.path == "/api/assets" and (.body | contains("運動会 2024 2024-06-01 t01.mp4"))')"
check "  both albums created" test "$(requests '.path == "/api/albums" and .method == "POST"' | wc -l)" = 2
check "  work dir deleted" test ! -e "$T/work/fp1"
check "  fingerprint recorded" grep -qx fp1 "$T/state/done.log"
check "  success notification names the folder" \
    test -n "$(requests '.path == "/hook" and (.body | contains("Disc backed up") and contains("(2)"))')"

echo "── resume: SAVE_DIR missing (unmounted share)"
: >"$LOG"
make_work fp2
run --resume DESTINATION=path SAVE_DIR="$T/not-mounted" NOTIFY=webhook WEBHOOK_URL="$M/hook"
check "resume fails (exit 3)" test "$rc" = 3
check "  work dir kept for a later resume" test -f "$T/work/fp2/rip.done"
check "  failure notification says why" \
    test -n "$(requests '.path == "/hook" and (.body | contains("not mounted"))')"
check "  SAVE_DIR not created" test ! -e "$T/not-mounted"
mkdir "$T/not-mounted"
run --resume DESTINATION=path SAVE_DIR="$T/not-mounted"
check "  a resume after mounting finishes it" test "$rc" = 0 -a ! -e "$T/work/fp2"

echo "── setup.sh"
check "setup.sh parses" bash -n "$REPO/setup.sh"
"$REPO/setup.sh" --help >"$T/out"
check "setup.sh --help" grep -q -- --libdvdcss "$T/out"

echo
if [ "$fails" -gt 0 ]; then echo "$fails test(s) FAILED"; exit 1; fi
echo "all tests passed"
