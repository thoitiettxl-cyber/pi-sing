#!/bin/bash
# Build the flashable Pi-Sing zip: module/ -> dist/Pi-Sing-<version>.zip
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
MOD="${ROOT}/module"
DIST="${ROOT}/dist"
VER="$(sed -n 's/^version=//p' "${MOD}/module.prop")"
OUT="${DIST}/Pi-Sing-${VER}.zip"

[ -x "${MOD}/payload/bin/sing-box" ] || { echo "missing module/payload/bin/sing-box"; exit 1; }

SINGBOX_BIN="${SINGBOX_BIN:-}" bash "${ROOT}/tests/smoke-check.sh" || exit 1

mkdir -p "$DIST"
rm -f "$OUT"

cd "$MOD"
FILES="module.prop customize.sh service.sh action.sh uninstall.sh
META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script"
PAYLOAD="payload/settings.ini payload/config.json payload/config.example.json
payload/package.list.cfg payload/ap.list.cfg payload/pi-sing payload/pi.iptables
payload/sing-box.LICENSE payload/bin/sing-box"

if command -v zip >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    zip -q -X -9 "$OUT" $FILES $PAYLOAD -x '*.DS_Store'
else
    python3 - "$OUT" $FILES $PAYLOAD <<'PY'
import os, sys, zipfile
out, files = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for f in files:
        st = os.stat(f)
        info = zipfile.ZipInfo(f, date_time=(2025, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = ((0o755 if st.st_mode & 0o100 else 0o644) | 0o100000) << 16
        with open(f, 'rb') as fh:
            z.writestr(info, fh.read())
PY
fi

echo
echo "built: $OUT"
ls -lh "$OUT" | awk '{print "size : "$5}'
sha256sum "$OUT" | awk '{print "sha256: "$1}'
python3 - "$OUT" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    names = z.namelist()
    print("files :", len(names))
    for n in names:
        print("   ", n)
PY
