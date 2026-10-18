#!/usr/bin/env bash
# Static checks, the same locally and in CI:
#   • shellcheck on every shell script (default checks + the optional ones in .shellcheckrc)
#   • VERSION in coaster.sh matches the newest CHANGELOG entry
#   • systemd-analyze verify on the units (syntax, ExecStart, dependencies)
#   • systemd-analyze security: fail if a unit's exposure score rises above MAX_EXPOSURE
#     (0–10; mount/eject need root, so a few points stay)
# Needs shellcheck and systemd ≥ 250.   Usage: tests/lint.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MAX_EXPOSURE="${MAX_EXPOSURE:-6.5}"
cd "$REPO"

echo "── shellcheck $(shellcheck --version | sed -n 's/^version: //p')"
shellcheck coaster.sh setup.sh tests/*.sh

echo "── version"
version="$(sed -n 's/^VERSION=//p' coaster.sh)"
changelog="$(sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' CHANGELOG.md | head -n1)"
if [ "$version" != "$changelog" ]; then
    echo "coaster.sh VERSION=$version but the newest CHANGELOG entry is $changelog"; exit 1
fi
echo "$version"

echo "── systemd-analyze verify"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
install -D -m 0755 coaster.sh "$root/usr/local/sbin/coaster"
install -D -m 0644 -t "$root/etc/systemd/system" systemd/*.service
mkdir -p "$root/usr/lib/systemd"   # stock targets (sysinit.target, …); older systemd needs them in --root
cp -r /usr/lib/systemd/system "$root/usr/lib/systemd/"
systemd-analyze verify --root="$root" coaster@sr0.service coaster-resume.service coaster-watch.service

echo "── systemd-analyze security (max exposure $MAX_EXPOSURE)"
systemd-analyze security --offline=true --threshold="${MAX_EXPOSURE/./}" systemd/*.service \
    | grep -E 'Overall exposure'

echo "lint passed"
