#!/bin/bash
# Validate the module payload before publishing:
#   - every shell script parses (POSIX sh, dash)
#   - config.json / config.example.json pass `sing-box check`
# Usage: tests/smoke-check.sh [path-to-sing-box]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
PAYLOAD="${ROOT}/module/payload"
SB="${1:-${SINGBOX_BIN:-}}"
FAIL=0

say() { printf '%-52s %s\n' "$1" "$2"; }

echo "== shell syntax (dash)"
for f in "${ROOT}"/module/*.sh "${PAYLOAD}/bin/pi-sing" "${PAYLOAD}/bin/pi.iptables" \
         "${PAYLOAD}/settings.ini" "${ROOT}"/module/META-INF/com/google/android/update-binary \
         "${HERE}"/*.sh; do
    [ -f "$f" ] || continue
    if sh -n "$f" 2>/tmp/pi-sing-sh.err; then
        say "${f#${ROOT}/}" ok
    else
        say "${f#${ROOT}/}" "FAIL: $(tr '\n' ' ' < /tmp/pi-sing-sh.err)"
        FAIL=$((FAIL + 1))
    fi
done

echo "== config"
if [ -z "$SB" ] || [ ! -x "$SB" ]; then
    say "sing-box check" "skipped (pass a sing-box binary as \$1)"
else
    for c in config/config.json config/config.example.json; do
        if "$SB" check -D "$PAYLOAD" -c "${PAYLOAD}/${c}" >/tmp/pi-sing-check.err 2>&1; then
            say "$c" "ok ($("$SB" version 2>/dev/null | head -n1))"
        else
            say "$c" "FAIL: $(tr '\n' ' ' < /tmp/pi-sing-check.err)"
            FAIL=$((FAIL + 1))
        fi
    done
fi

echo "== payload completeness"
# A thin build deliberately ships no core; everything else is mandatory.
FILES="bin/pi-sing bin/pi.iptables settings.ini"
FILES="$FILES config/config.json config/config.example.json"
FILES="$FILES lists/package.list.cfg lists/ap.list.cfg"
[ "${PISING_THIN:-0}" = "1" ] || FILES="$FILES bin/sing-box"
for f in $FILES; do
    if [ -e "${PAYLOAD}/${f}" ]; then
        say "$f" "ok"
    else
        say "$f" "MISSING"
        FAIL=$((FAIL + 1))
    fi
done

echo
[ "$FAIL" -eq 0 ] && echo "smoke check: pass" || echo "smoke check: ${FAIL} failure(s)"
[ "$FAIL" -eq 0 ]
