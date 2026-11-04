#!/bin/bash
# Installer test for customize.sh (Linux host, no device needed).
#
# customize.sh is the only place that decides the on-device layout, and its
# migration path only ever runs on an upgrade, so it is exercised here against a
# throw-away DATA/MODPATH:
#   1. fresh install -> flat files under the documented directories
#   2. upgrade from the v1.0.0 flat layout -> user files moved, not clobbered
#   3. running the upgrade twice moves nothing (idempotent)
#   4. a stale watchdog loop from v1.0.0 is stopped
#   5. a thin zip (no core) installs without one and points at update-core
#   6. a thin zip over an existing core keeps that core and asks nothing
#   7. a requested core download that fails does not abort the flash
#   8. pi-sing refuses a pre-v1.1.0 settings.ini instead of resolving paths on "/"
#
# Two substitutions are made on the copy of customize.sh under test:
#   DATA=/data/adb/pi-sing -> a temp dir, and /dev/pi-sing -> a temp symlink, so
#   the test never touches the real device paths.
#
# Usage: tests/installer-test.sh [zip]     (default: stage one from module/)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d /tmp/pising-inst.XXXXXX)"
PASS=0
FAIL=0

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got '$1', want '$2')"; }

cleanup() {
    [ "${FAIL:-1}" -eq 0 ] && rm -rf "$TMP" || printf '  ---- kept %s\n' "$TMP"
}
trap cleanup EXIT

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (zip/unzip stub)"; exit 1; }

# unzip is not present on every build host; this stub covers the two calls
# customize.sh makes (-o ZIP pattern... -d DIR).
cat > "${TMP}/unzip.py" <<'PY'
import sys, zipfile, fnmatch
args = sys.argv[1:]
zpath, dest, pats = args[1], ".", []
i = 2
while i < len(args):
    if args[i] == "-d":
        dest = args[i + 1]; i += 2; continue
    pats.append(args[i]); i += 1
with zipfile.ZipFile(zpath) as z:
    for n in z.namelist():
        if any(fnmatch.fnmatch(n, p) for p in pats):
            z.extract(n, dest)
PY

stage_zip() {
    Z="${TMP}/Pi-Sing-test.zip"
    cp -a "${ROOT}/module" "${TMP}/module"
    # The sing-box binary is not committed; any file works for a copy check.
    [ -f "${TMP}/module/payload/bin/sing-box" ] || printf 'stub\n' > "${TMP}/module/payload/bin/sing-box"
    python3 - "$Z" "${TMP}/module" <<'PY'
import os, sys, zipfile
out, mod = sys.argv[1], sys.argv[2]
files = ["module.prop", "customize.sh", "service.sh", "action.sh", "uninstall.sh",
         "META-INF/com/google/android/update-binary",
         "META-INF/com/google/android/updater-script"]
files += [os.path.relpath(os.path.join(d, f), mod)
          for d, _, fs in os.walk(os.path.join(mod, "payload")) for f in fs]
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
    for f in files:
        z.write(os.path.join(mod, f), f)
PY
}

with_core() {  # $1 = source zip, $2 = output zip with payload/bin/sing-box present
    python3 - "$1" "$2" <<'PY'
import sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zo:
    names = zi.namelist()
    for item in zi.infolist():
        zo.writestr(item, zi.read(item.filename))
    if "payload/bin/sing-box" not in names:
        zo.writestr("payload/bin/sing-box", "stub\n")
PY
}

strip_core() {  # $1 = source zip, $2 = thin zip (same payload, no core)
    python3 - "$1" "$2" <<'PY'
import sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zo:
    for item in zi.infolist():
        if item.filename == "payload/bin/sing-box":
            continue
        zo.writestr(item, zi.read(item.filename))
PY
}

install_into() {  # $1 = DATA, $2 = MODPATH, $3 = log tag, $4 = zip (default $Z)
    _zip="${4:-$Z}"
    sed -e "s|^DATA=/data/adb/pi-sing$|DATA=$1|" \
        -e "s|/dev/pi-sing|${TMP}/dev-pi-sing|g" \
        "${ROOT}/module/customize.sh" > "${TMP}/customize.sh"
    mkdir -p "$2"
    BOOTMODE=true KSU=false APATCH=false PISING_TEST_TMP="$TMP" \
    ZIPFILE="$_zip" MODPATH="$2" TMPDIR="${TMP}/tmp" \
    sh -c '
        abort() { echo "ABORT: $*" >&2; exit 1; }
        ui_print() { echo "$*"; }
        set_perm() { :; }
        set_perm_recursive() { :; }
        unzip() { python3 "$PISING_TEST_TMP/unzip.py" "$@"; }
        . '"${TMP}"'/customize.sh
    ' > "${TMP}/log-$3" 2>&1 || { bad "installer run ($3)"; cat "${TMP}/log-$3"; return 1; }
}

if [ $# -gt 0 ]; then Z="$1"; else stage_zip; fi
[ -f "$Z" ] || { echo "missing zip: $Z"; exit 1; }

# The artifact as built, then the two variants the cases need: the core-dependent
# cases want a zip that carries a core (a --thin artifact does not, so a stub is
# added here), the thin cases want the same payload without one.
Z_ART="$Z"
Z_THIN="${TMP}/Pi-Sing-thin.zip"
strip_core "$Z_ART" "$Z_THIN" || { echo "cannot derive the thin zip from $Z_ART"; exit 1; }
Z="${TMP}/Pi-Sing-with-core.zip"
with_core "$Z_ART" "$Z" || { echo "cannot derive the full zip from $Z_ART"; exit 1; }

echo "== fresh install"
DATA="${TMP}/fresh"
install_into "$DATA" "${TMP}/mod-fresh" fresh || { echo; echo "installer test: abort"; exit 1; }
eq "$(find "$DATA" -type f | wc -l | tr -d ' ')" 9 "9 files installed"
eq "$(ls "$DATA" | LC_ALL=C sort | tr '\n' ' ')" "bin config lists pi-sing pi.iptables run settings.ini " "top level: settings.ini + 4 dirs + 2 compat links"
eq "$(readlink "$DATA/pi-sing")" "$DATA/bin/pi-sing" "compat link pi-sing -> bin/pi-sing (pre-reboot service.sh)"
eq "$(readlink "$DATA/pi.iptables")" "$DATA/bin/pi.iptables" "compat link pi.iptables -> bin/pi.iptables"
for f in bin/pi-sing bin/pi.iptables bin/sing-box config/config.json \
         config/config.example.json lists/package.list.cfg lists/ap.list.cfg; do
    [ -f "$DATA/$f" ] && ok "$f" || bad "missing $f"
done
eq "$(readlink "${TMP}/dev-pi-sing")" "$DATA/bin/pi-sing" "shortcut points at bin/pi-sing"
grep -q '^bin_dir=' "$DATA/settings.ini" && ok "settings.ini defines bin_dir" || bad "settings.ini has no bin_dir"

echo "== upgrade from the v1.0.0 flat layout"
DATA="${TMP}/upgrade"
mkdir -p "$DATA/run"
for f in pi-sing pi.iptables; do echo "OLD $f" > "$DATA/$f"; done
# A real v1.0.0 settings.ini: flat paths only, plus a user edit.
{
    printf 'tproxy_port=2536\n'
    printf 'data_dir="%s"\n' "$DATA"
    printf 'uid_file="${data_dir}/run/appuid.list"\n'
    printf 'defaults_dir="${data_dir}"\n'
} > "$DATA/settings.ini"
echo '{"user":true}' > "$DATA/config.json"
echo '{"example":1}' > "$DATA/config.example.json"
echo 'com.example' > "$DATA/package.list.cfg"
echo 'allow wlan1' > "$DATA/ap.list.cfg"
echo 'old cache' > "$DATA/cache.db"
echo 'old log' > "$DATA/run/pi-sing.log"
# A watchdog left over from v1.0.0 keeps restarting the core from the old script;
# it must be killed before the paths move. SIGTERM is ignored on purpose: on the
# target ROM the loop survives it, so the installer has to escalate to SIGKILL.
bash -c 'trap "" TERM; exec -a "'"$DATA"'/pi-sing watchdog" sleep 60' &
STALE=$!
disown "$STALE" 2>/dev/null || true
sleep 1
install_into "$DATA" "${TMP}/mod-upgrade" upgrade || { echo; echo "installer test: abort"; exit 1; }
kill -0 "$STALE" 2>/dev/null && bad "stale watchdog survived the upgrade" || ok "stale watchdog killed"
grep -q 'stopped: watchdog pid .*SIGKILL' "${TMP}/log-upgrade" && ok "SIGTERM ignored -> escalated to SIGKILL" ||
    bad "SIGKILL escalation not reported"
kill -9 "$STALE" 2>/dev/null
eq "$(grep -c '^tproxy_port=2536$' "$DATA/settings.ini")" 1 "settings.ini kept (user value intact)"
eq "$(cat "$DATA/config/config.json")" '{"user":true}' "config.json moved into config/, content kept"
eq "$(cat "$DATA/lists/package.list.cfg")" "com.example" "package.list.cfg moved into lists/"
eq "$(cat "$DATA/run/cache.db")" "old cache" "cache.db moved into run/"
eq "$(grep -c '^bin_dir=' "$DATA/settings.ini")" 1 "path block appended to the old settings.ini"
eq "$(grep -c '^data_dir=' "$DATA/settings.ini")" 1 "settings.ini not rewritten (one data_dir)"
eq "$(PISING_DIR="$DATA" sh -c '. "$PISING_DIR/settings.ini"; printf "%s|%s|%s" "$bin_dir" "$config_dir" "$list_dir"')" \
   "$DATA/bin|$DATA/config|$DATA/lists" "appended block resolves the new layout"
eq "$(head -c 3 "$DATA/bin/pi-sing")" "#!/" "bin/pi-sing is the new script, not the old one"
[ -L "$DATA/pi-sing" ] && ok "old flat pi-sing replaced by a compat symlink" || bad "old flat pi-sing still a file"
eq "$(ls "$DATA" | LC_ALL=C sort | tr '\n' ' ')" "bin config lists pi-sing pi.iptables run settings.ini " "no flat files left at the top"
grep -q 'moved : pi-sing -> bin/pi-sing' "${TMP}/log-upgrade" && ok "migration is reported" || bad "migration not reported"
eq "$(head -c 3 "$DATA/bin/pi-sing")" "#!/" "bin/pi-sing still a real script after re-install"

echo "== upgrade twice (idempotent)"
install_into "$DATA" "${TMP}/mod-upgrade2" upgrade2 || { echo; echo "installer test: abort"; exit 1; }
grep -q 'moved :' "${TMP}/log-upgrade2" && bad "second upgrade moved something again" || ok "second upgrade moves nothing"
eq "$(cat "$DATA/config/config.json")" '{"user":true}' "user config still kept"

echo "== pi-sing refuses a pre-v1.1.0 settings.ini"
echo "== thin zip (no core), fresh install, download skipped"
DATA="${TMP}/thin"
export PISING_INSTALL_CORE=0
install_into "$DATA" "${TMP}/mod-thin" thin "$Z_THIN" || { echo; echo "installer test: abort"; exit 1; }
unset PISING_INSTALL_CORE
eq "$(find "$DATA" -type f | wc -l | tr -d ' ')" 8 "8 files installed (no core)"
[ -e "$DATA/bin/sing-box" ] && bad "a core came out of a thin zip" || ok "no core in bin/"
[ -f "$DATA/bin/pi-sing" ] && ok "CLI installed" || bad "CLI missing"
[ -f "$DATA/bin/sing-box.LICENSE" ] && ok "licence still shipped in a thin zip" || bad "licence missing"
grep -q 'core  : none installed' "${TMP}/log-thin" && ok "installer says the core is missing" ||
    bad "no notice about the missing core"
grep -q 'update-core' "${TMP}/log-thin" && ok "notice says how to finish" ||
    bad "notice does not name update-core"

echo "== thin zip over a phone that already has a core"
SUM_BEFORE="$(sha256sum "${TMP}/fresh/bin/sing-box" | awk '{ print $1 }')"
DATA="${TMP}/fresh"
install_into "$DATA" "${TMP}/mod-thin-keep" thin-keep "$Z_THIN" || { echo; echo "installer test: abort"; exit 1; }
eq "$(sha256sum "$DATA/bin/sing-box" | awk '{ print $1 }')" "$SUM_BEFORE" "existing core left untouched"
grep -q 'core  : kept the one already in' "${TMP}/log-thin-keep" && ok "installer reports the kept core" ||
    bad "kept core not reported"
grep -q 'Volume UP' "${TMP}/log-thin-keep" && bad "asked although a core is installed" ||
    ok "no question when a core is already there"

echo "== thin zip, download selected, no network"
DATA="${TMP}/thin-dl"
export PISING_INSTALL_CORE=1 PISING_UPDATE_API="http://127.0.0.1:1/releases/latest" PISING_UPDATE_ARCH=arm64
install_into "$DATA" "${TMP}/mod-thin-dl" thin-dl "$Z_THIN" || { echo; echo "installer test: abort"; exit 1; }
unset PISING_INSTALL_CORE PISING_UPDATE_API PISING_UPDATE_ARCH
[ -e "$DATA/bin/sing-box" ] && bad "a core appeared without a server" || ok "no core after a failed download"
grep -q 'download failed, install continues' "${TMP}/log-thin-dl" && ok "failed download does not abort the flash" ||
    bad "failed download not reported"
grep -q 'core  : none installed' "${TMP}/log-thin-dl" && ok "next step printed after the failure" ||
    bad "next step missing after the failure"
grep -q 'update: cannot fetch' "$DATA/run/pi-sing.log" && ok "update-core left its reason in run/pi-sing.log" ||
    bad "no diagnosis in run/pi-sing.log"

echo "== pi-sing refuses a pre-v1.1.0 settings.ini"
OLD="${TMP}/old"
mkdir -p "$OLD/run" "$OLD/bin"
printf 'data_dir="%s"\nuid_file="${data_dir}/run/appuid.list"\n' "$OLD" > "$OLD/settings.ini"
cp "${ROOT}/module/payload/bin/pi-sing" "$OLD/bin/"
OUT="$(PISING_DIR="$OLD" sh "$OLD/bin/pi-sing" status 2>&1)"; RC=$?
eq "$RC" 1 "exit code 1"
case "$OUT" in
    *"older layout"*) ok "message names the problem: $(printf '%s' "$OUT" | head -n 1)" ;;
    *) bad "unexpected message: $OUT" ;;
esac

echo
printf '==> %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
