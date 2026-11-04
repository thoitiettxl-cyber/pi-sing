#!/bin/bash
# Build the flashable Pi-Sing module: module/ -> dist/Pi-Sing-<version>.zip
#
# The zip never carries the sing-box core (79 MiB unpacked). The module gets one
# on the phone, three ways:
#   - at flash time: the installer always asks, (+) runs `update-core`
#   - later:         su -c pi-sing update-core
#   - by hand:       put a binary at /data/adb/pi-sing/bin/sing-box (chmod 755)
# One artifact, no "thin" variant; `--thin`/`--all` are accepted so old commands
# keep working, `--full` is refused.
#
#   tools/build.sh            the module zip, no core
set -eu


HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
MOD="${ROOT}/module"
DIST="${ROOT}/dist"
VER="$(sed -n 's/^version=//p' "${MOD}/module.prop")"

case "${1:-}" in
    ""|--thin|--all) ;;
    --full) echo "the core is never bundled any more: flash the module and let it download one (update-core)" >&2; exit 1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
esac

FILES="module.prop customize.sh service.sh action.sh uninstall.sh
META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script"
SMALL="payload/settings.ini payload/config/config.json payload/config/config.example.json
payload/lists/package.list.cfg payload/lists/ap.list.cfg
payload/bin/pi-sing payload/bin/pi.iptables payload/bin/sing-box.LICENSE"

build() {
    OUT="${DIST}/Pi-Sing-${VER}.zip"
    PAYLOAD="${SMALL}"
    SINGBOX_BIN="${SINGBOX_BIN:-}" bash "${ROOT}/tests/smoke-check.sh" || return 1

    mkdir -p "$DIST"
    rm -f "$OUT"

    cd "$MOD"
    if command -v zip >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        zip -q -X -9 "$OUT" $FILES $PAYLOAD -x '*.DS_Store'
    else
        # shellcheck disable=SC2086
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
    cd "$ROOT"

    echo
    echo "built: $OUT (module only, no core)"
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

    # The CLI behaviour (dashboard path, log split, description), the action
    # button's fail-closed recovery, and the installer (the only thing that
    # knows the on-device layout) all run without a device.
    echo
    bash "${ROOT}/tests/cli-test.sh"
    echo
    bash "${ROOT}/tests/action-test.sh"
    echo
    bash "${ROOT}/tests/installer-test.sh" "$OUT"
}

build
