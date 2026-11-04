#!/bin/bash
# Download and verify one sing-box binary.
#
# The release zip never carries a core and the binary is not committed: it is
# 79 MiB and it is GPL-3.0 software from another project. The module installs its
# own core with `update-core`. This is for the host tests (smoke-check,
# netns-tproxy-test) and for installing a core by hand:
#   tools/fetch-sing-box.sh && adb push module/payload/bin/sing-box /data/local/tmp/
#   su -c 'cp /data/local/tmp/sing-box /data/adb/pi-sing/bin/ && chmod 755 ...'
#
# Usage: tools/fetch-sing-box.sh [--arch arm64|arm|x86_64|x86] [--out path]
#
# Note: module/payload/bin/sing-box is gitignored, and the build leaves it out.
set -eu

VERSION="1.14.4"
TARBALL_SHA256="fb3a6c5197f4044f82c8fd75e01ce14c28b6abdd4c3df84bb987d41a962a320f"
BB_SHA256=""

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${HERE}/../module/payload/bin/sing-box"
ARCH="arm64"

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

case "$ARCH" in
    arm64)  ABITAG="arm64" TIMEOUT_TAG="arm64" ;;
    arm)    ABITAG="arm"   TIMEOUT_TAG="arm" ;;
    x86_64) ABITAG="amd64" TIMEOUT_TAG="amd64" ;;
    x86)    ABITAG="386"   TIMEOUT_TAG="386" ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

TARBALL="sing-box-${VERSION}-android-${ABITAG}.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${TARBALL}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading ${URL}"
curl -fL --retry 3 -o "${TMP}/${TARBALL}" "$URL"
echo "${TARBALL_SHA256}  ${TMP}/${TARBALL}" | sha256sum -c - >/dev/null ||
    { echo "sha256 mismatch for ${TARBALL}" >&2; exit 1; }

tar -xzf "${TMP}/${TARBALL}" -C "$TMP"
mkdir -p "$(dirname "$OUT")"
cp -f "${TMP}/sing-box-${VERSION}-android-${ABITAG}/sing-box" "$OUT"
cp -f "${TMP}/sing-box-${VERSION}-android-${ABITAG}/LICENSE" "$(dirname "$OUT")/sing-box.LICENSE"
chmod 755 "$OUT"
echo "installed: ${OUT}"
"$OUT" version 2>/dev/null | head -n 1 || true
