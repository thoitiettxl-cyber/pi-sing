#!/bin/bash
# Installer test for customize.sh (Linux host, no device needed).
#
# customize.sh is the only place that decides the on-device layout, and its
# migration path only ever runs on an upgrade, so it is exercised here against a
# throw-away DATA/MODPATH:
#   1. fresh install -> directories, real wrapper files (no symlinks), state line
#   2. upgrade from the v1.0.0 flat layout -> user files moved, not clobbered
#   3. running the upgrade twice moves nothing (idempotent), legacy run/ui moved
#   4. a stale watchdog loop from v1.0.0 is stopped
#   5. a thin zip (no core) installs without one and points at update-core
#   6. a thin zip over an existing core keeps that core, after the (-) prompt
#   7. the volume-key prompt is shown for every zip: (+) asks update-core, (-) keeps
#   8. a requested core download that fails does not abort the flash
#   9. pi-sing refuses a pre-v1.1.0 settings.ini instead of resolving paths on "/"
#
# The copy of customize.sh under test has DATA=/data/adb/pi-sing rewritten to a
# temp dir and /dev/pi-sing to a temp file, so it never touches the device paths.
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

# The installer always asks the core question. Every case answers it through
# PISING_INSTALL_CORE unless it is testing the key press itself.
export PISING_INSTALL_CORE=0
# A fake getevent that reports a pressed key; the prompt test selects it.
mkdir -p "${TMP}/keyup" "${TMP}/keydown"
printf '#!/bin/sh\necho "  KEY_VOLUMEUP       DOWN"\n'   > "${TMP}/keyup/getevent"
printf '#!/bin/sh\necho "  KEY_VOLUMEDOWN     DOWN"\n' > "${TMP}/keydown/getevent"
chmod 755 "${TMP}/keyup/getevent" "${TMP}/keydown/getevent"

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
eq "$(find "$DATA" -type f | wc -l | tr -d ' ')" 11 "11 files installed"
eq "$(ls "$DATA" | LC_ALL=C sort | tr '\n' ' ')" "bin config lists pi-sing pi.iptables run settings.ini " "top level: settings.ini + 4 dirs + 2 entry points"
[ -f "$DATA/pi-sing" ] && [ ! -L "$DATA/pi-sing" ] && ok "pi-sing is a real wrapper file, not a symlink" ||
    bad "pi-sing is missing or still a symlink"
grep -q "exec $DATA/bin/pi-sing \"\$@\"" "$DATA/pi-sing" && ok "wrapper execs bin/pi-sing" ||
    bad "wrapper does not exec bin/pi-sing"
[ -f "$DATA/pi.iptables" ] && [ ! -L "$DATA/pi.iptables" ] && ok "pi.iptables is a real wrapper file" ||
    bad "pi.iptables is missing or still a symlink"
for f in bin/pi-sing bin/pi.iptables bin/sing-box config/config.json \
         config/config.example.json lists/package.list.cfg lists/ap.list.cfg; do
    [ -f "$DATA/$f" ] && ok "$f" || bad "missing $f"
done
[ -f "${TMP}/dev-pi-sing" ] && [ ! -L "${TMP}/dev-pi-sing" ] && ok "shortcut is a real file" ||
    bad "shortcut missing or a symlink"
grep -q "exec $DATA/bin/pi-sing" "${TMP}/dev-pi-sing" && ok "shortcut execs bin/pi-sing" ||
    bad "shortcut does not exec bin/pi-sing"
grep -q '^bin_dir=' "$DATA/settings.ini" && ok "settings.ini defines bin_dir" || bad "settings.ini has no bin_dir"
grep -q '^log_dir=' "$DATA/settings.ini" && ok "settings.ini defines log_dir" || bad "settings.ini has no log_dir"
grep -q '^description=⚪ Installed' "${TMP}/mod-fresh/module.prop" && ok "staged module.prop shows the install state" ||
    bad "staged module.prop does not show the install state"
grep -q 'keys   : (-) keep selected' "${TMP}/log-fresh" && ok "PISING_INSTALL_CORE=0 answers the prompt without a key" ||
    bad "the installer did not answer the prompt"

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
eq "$(grep -c '^log_dir=' "$DATA/settings.ini")" 1 "log_dir appended to the old settings.ini"
[ -e "$DATA/run/pi-sing.log" ] && bad "the old flat log file was left behind" || ok "old flat logs removed"
[ -f "$DATA/run/log/module.log" ] && bad "a log appeared before anything ran" || ok "run/log is ready for the new logs"
eq "$(grep -c '^data_dir=' "$DATA/settings.ini")" 1 "settings.ini not rewritten (one data_dir)"
eq "$(PISING_DIR="$DATA" sh -c '. "$PISING_DIR/settings.ini"; printf "%s|%s|%s" "$bin_dir" "$config_dir" "$list_dir"')" \
   "$DATA/bin|$DATA/config|$DATA/lists" "appended block resolves the new layout"
eq "$(head -c 3 "$DATA/bin/pi-sing")" "#!/" "bin/pi-sing is the new script, not the old one"
[ -f "$DATA/pi-sing" ] && [ ! -L "$DATA/pi-sing" ] && ok "old flat pi-sing replaced by a wrapper file" || bad "old flat pi-sing not replaced by a wrapper"
eq "$(ls "$DATA" | LC_ALL=C sort | tr '\n' ' ')" "bin config lists pi-sing pi.iptables run settings.ini " "no flat files left at the top"
grep -q 'moved : pi-sing -> bin/pi-sing' "${TMP}/log-upgrade" && ok "migration is reported" || bad "migration not reported"
eq "$(head -c 3 "$DATA/bin/pi-sing")" "#!/" "bin/pi-sing still a real script after re-install"

echo "== upgrade twice (idempotent)"
# A dashboard created by the old -D run/ layout lives in run/ui; the new rule
# resolves a relative "ui" next to config.json, so the installer moves it once.
CFG_UI='{"user":true,"services":[{"type":"api","dashboard":"ui"}]}'
echo "$CFG_UI" > "$DATA/config/config.json"
mkdir -p "$DATA/run/ui" && echo '<html>old</html>' > "$DATA/run/ui/index.html"
install_into "$DATA" "${TMP}/mod-upgrade2" upgrade2 || { echo; echo "installer test: abort"; exit 1; }
eq "$(cat "$DATA/config/ui/index.html" 2>/dev/null)" "<html>old</html>" "run/ui moved next to config.json"
[ -d "$DATA/run/ui" ] && bad "run/ui left behind after the move" || ok "run/ui is gone"
grep -q 'moved : run/ui -> config/ui' "${TMP}/log-upgrade2" && ok "the move is reported" ||
    bad "the dashboard move is not reported"
grep -q 'moved : config' "${TMP}/log-upgrade2" && bad "second upgrade moved a data file again" ||
    ok "second upgrade moves no user data"
eq "$(cat "$DATA/config/config.json")" "$CFG_UI" "user config still kept (dashboard line included)"

echo "== pi-sing refuses a pre-v1.1.0 settings.ini"
echo "== thin zip (no core), fresh install, download skipped"
DATA="${TMP}/thin"
export PISING_INSTALL_CORE=0
install_into "$DATA" "${TMP}/mod-thin" thin "$Z_THIN" || { echo; echo "installer test: abort"; exit 1; }
export PISING_INSTALL_CORE=0
eq "$(find "$DATA" -type f | wc -l | tr -d ' ')" 10 "10 files installed (no core)"
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
grep -q 'core  : kept ' "${TMP}/log-thin-keep" && ok "installer reports the kept core" ||
    bad "kept core not reported"
grep -q 'keys   : (-) keep selected' "${TMP}/log-thin-keep" && ok "(-) / PISING_INSTALL_CORE=0 keeps the core" ||
    bad "the keep answer was not reported"

echo "== thin zip, download selected, no network"
DATA="${TMP}/thin-dl"
export PISING_INSTALL_CORE=1 PISING_UPDATE_API="http://127.0.0.1:1/releases/latest" PISING_UPDATE_ARCH=arm64
install_into "$DATA" "${TMP}/mod-thin-dl" thin-dl "$Z_THIN" || { echo; echo "installer test: abort"; exit 1; }
unset PISING_INSTALL_CORE PISING_UPDATE_API PISING_UPDATE_ARCH
[ -e "$DATA/bin/sing-box" ] && bad "a core appeared without a server" || ok "no core after a failed download"
grep -q 'update failed, keeping what is installed' "${TMP}/log-thin-dl" && ok "failed download does not abort the flash" ||
    bad "failed download not reported"
grep -q 'core  : none installed' "${TMP}/log-thin-dl" && ok "next step printed after the failure" ||
    bad "next step missing after the failure"
grep -q 'update: cannot fetch' "$DATA/run/log/module.log" && ok "update-core left its reason in run/log/module.log" ||
    bad "no diagnosis in run/log/module.log"

echo "== volume key (+) pressed: update-core is asked, a failure keeps the bundled core"
DATA="${TMP}/key-up"
rm -f "${TMP}/dev-pi-sing"
(
    unset PISING_INSTALL_CORE
    export PISING_UPDATE_API="http://127.0.0.1:1/releases/latest" PISING_UPDATE_ARCH=arm64
    PATH="${TMP}/keyup:$PATH" install_into "$DATA" "${TMP}/mod-keyup" keyup "$Z"
) || { echo; echo "installer test: abort"; exit 1; }
grep -q '(+) UP' "${TMP}/log-keyup" && ok "the (+) key is documented in the prompt" ||
    bad "the prompt does not document (+)"
grep -q 'keys   : (+) pressed' "${TMP}/log-keyup" && ok "the key press is detected" ||
    bad "the key press was not detected"
grep -q 'core  : update failed, keeping what is installed' "${TMP}/log-keyup" && ok "a failed update keeps the bundled core" ||
    bad "a failed update was not handled"
[ -f "$DATA/bin/sing-box" ] && ok "the bundled core is still there" || bad "the bundled core disappeared"
grep -q 'update: cannot fetch' "$DATA/run/log/module.log" 2>/dev/null && ok "update-core left its reason in run/log/module.log" ||
    bad "no diagnosis in run/log/module.log"

echo "== volume key (-) pressed: a thin zip keeps no core and downloads nothing"
DATA="${TMP}/key-down"
(
    unset PISING_INSTALL_CORE
    PATH="${TMP}/keydown:$PATH" install_into "$DATA" "${TMP}/mod-keydown" keydown "$Z_THIN"
) || { echo; echo "installer test: abort"; exit 1; }
grep -q 'keys   : (-) pressed' "${TMP}/log-keydown" && ok "the (-) key is detected" ||
    bad "the (-) key was not detected"
[ -e "$DATA/bin/sing-box" ] && bad "a core came out of a thin zip" || ok "no core after (-)"
grep -q 'update: ' "$DATA/run/log/module.log" 2>/dev/null && bad "(-) still ran update-core" ||
    ok "(-) did not contact GitHub"

echo "== a burst of non-key input does not shorten the prompt window"
# `getevent -lqc 1` returns on the first event of any kind, and this phone
# streams touch/nav events (measured: 5 reads = 787 ms), so a loop that counts
# reads ran its 15 iterations in ~2.4 s while promising 15 s. The wait has to be
# a wall-clock deadline: with an input device that never sends a volume key the
# old loop answered after exactly 15 reads, the new one reads until the deadline.
mkdir -p "${TMP}/keyburst"
: > "${TMP}/keyburst.calls"
cat > "${TMP}/keyburst/getevent" <<EOF
#!/bin/sh
echo x >> "${TMP}/keyburst.calls"
echo "    /dev/input/event7: EV_ABS       ABS_MT_POSITION_Y    0000991f"
exit 0
EOF
chmod 755 "${TMP}/keyburst/getevent"
DATA="${TMP}/keys"
(
    unset PISING_INSTALL_CORE
    PATH="${TMP}/keyburst:$PATH" PISING_KEY_WAIT=2 \
        install_into "$DATA" "${TMP}/mod-keys" keys "$Z_THIN"
) || { echo; echo "installer test: abort"; exit 1; }
_calls="$(wc -l < "${TMP}/keyburst.calls" | tr -d ' ')"
[ "$_calls" -gt 20 ] && ok "the prompt waited on the clock, not on the read count (${_calls} reads)" ||
    bad "the prompt gave up after ${_calls} reads"
grep -q 'Volume keys (2 s)' "${TMP}/log-keys" && ok "the prompt prints the window it really uses" ||
    bad "the prompt does not print the window"
grep -q 'keys   : no key pressed' "${TMP}/log-keys" && ok "no key -> keep, the flash goes on" ||
    bad "the no-input answer was not reported"

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
