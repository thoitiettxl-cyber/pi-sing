#!/system/bin/sh
# Pi-Sing installer (Magisk / KernelSU / APatch).
# The zip is not fully extracted by Magisk: this script decides what goes where.
#
# Everything that changes on the phone lives under /data/adb/pi-sing, grouped by
# purpose; only settings.ini is a real file at the top:
#   settings.ini
#   bin/      sing-box, pi-sing, pi.iptables (+ sing-box.LICENSE)
#   config/   config.json, config.example.json
#   lists/    package.list.cfg, ap.list.cfg
#   run/      pid, logs, generated lists, sing-box cache
#   pi-sing, pi.iptables -> bin/  (only until the manager applies the new
#                                  service.sh on the next boot)
SKIPUNZIP=1

DATA=/data/adb/pi-sing

[ "$BOOTMODE" = true ] || abort "! install from Magisk/KernelSU/APatch manager, not from recovery"

ui_print " "
ui_print "  Pi-Sing - sing-box + TPROXY"
ui_print "  ---------------------------"

case "$KSU" in
    true) ui_print "  manager      : KernelSU ${KSU_VER:-}" ;;
    *) case "$APATCH" in
           true) ui_print "  manager      : APatch $(cat /data/adb/ap/version 2>/dev/null)" ;;
           *) ui_print "  manager      : Magisk ${MAGISK_VER:-}" ;;
       esac ;;
esac

ui_print "  installing to: $DATA"
if command -v getprop >/dev/null 2>&1; then
    ui_print "  device       : $(getprop ro.product.cpu.abi 2>/dev/null)"
fi

# A watchdog loop from the previous version outlives `stop` and keeps restarting
# the core from a script whose paths are about to move, so it is killed first.
# /proc/<pid>/cmdline is read directly: ps and pgrep split their pattern on
# spaces (toybox: "a b" matches a OR b) and their visibility differs between
# init, su and the manager installer. SIGTERM is not enough — measured on the
# target ROM, the loop survives it — so escalate to SIGKILL.
watchdog_pids() {
    for _entry in /proc/[0-9]*; do
        _pid="${_entry#/proc/}"
        case "$_pid" in ''|*[!0-9]*) continue ;; esac
        [ "$_pid" = "$$" ] && continue
        # cat, not a redirect: a process can exit between readdir and open, and
        # the shell reports a redirection failure even with 2>/dev/null.
        _cmd="$(cat "$_entry/cmdline" 2>/dev/null | tr '\0' ' ')"
        case "$_cmd" in
            *"$DATA/bin/pi-sing watchdog"*|*"$DATA/pi-sing watchdog"*) printf '%s\n' "$_pid" ;;
        esac
    done
}

stop_watchdog() {
    for _pid in $(watchdog_pids); do
        kill -15 "$_pid" 2>/dev/null
        _n=0
        while [ "$_n" -lt 5 ] && kill -0 "$_pid" 2>/dev/null; do
            sleep 1
            _n=$((_n + 1))
        done
        if kill -0 "$_pid" 2>/dev/null; then
            kill -9 "$_pid" 2>/dev/null
            ui_print "  stopped: watchdog pid $_pid (SIGKILL after ${_n}s)"
        else
            ui_print "  stopped: watchdog pid $_pid"
        fi
    done
}
stop_watchdog

# ---------------------------------------------------------------- core choice
# One question, always asked, whatever the zip carries: check GitHub for a newer
# core, or keep the core in this zip / on the phone. The manager installer has no
# TTY, so the answer comes from the volume keys.
#
# The wait is a wall-clock deadline, not a number of reads: `getevent -lqc 1`
# returns on *any* input event (this phone streams touch/nav events), so counting
# iterations made the advertised 15 s last ~2.4 s (measured: 5 reads = 787 ms).
# box_for_magisk loops against `date +%s` for the same reason.
#
# Anything queued before the prompt is drained first, or a volume key pressed to
# scroll the manager log answers a question the user has not read yet.
# /dev/input is not readable in every installer context; then the default (keep)
# is taken instead of hanging. The flash itself never fails because of this.
flush_keys() {
    timeout 1 getevent -ql >/dev/null 2>&1
    return 0
}

read_volume_key() {  # $1 = seconds to wait -> "up" | "down" | nothing
    _until=$(( $(date +%s) + $1 ))
    while [ "$(date +%s)" -lt "$_until" ]; do
        _ev="$(timeout 1 getevent -lqc 1 2>/dev/null)"
        case "$_ev" in
            *KEY_VOLUMEUP*) printf 'up'; return 0 ;;
            *KEY_VOLUMEDOWN*) printf 'down'; return 0 ;;
        esac
    done
    return 1
}

# Sets ASK (1 = check GitHub for a newer core, 0 = keep) and prints the prompt.
# The prompt cannot come back on stdout: the caller would swallow it along with
# the answer. PISING_INSTALL_CORE=1|0 answers without a key press (unattended
# flashes and the installer test).
ASK=0
ask_core_update() {
    ASK=0
    case "${PISING_INSTALL_CORE:-ask}" in
        1|yes|download|update) ASK=1; ui_print "  keys   : (+) update selected (PISING_INSTALL_CORE)"; return 0 ;;
        0|no|keep|skip)        ui_print "  keys   : (-) keep selected (PISING_INSTALL_CORE)"; return 0 ;;
    esac
    if ! command -v getevent >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        ui_print "  keys   : no key input here, keeping the current core"
        return 0
    fi
    # PISING_KEY_WAIT is the same question with a shorter window (automation).
    _wait="${PISING_KEY_WAIT:-15}"
    case "$_wait" in ""|*[!0-9]*) _wait=15 ;; esac
    flush_keys
    ui_print " "
    ui_print "  Volume keys (${_wait} s):"
    ui_print "    (+) UP   = download the latest sing-box core from GitHub"
    ui_print "    (-) DOWN = keep the core already on the phone (none yet on a first flash)"
    ui_print "    no key   = keep"
    case "$(read_volume_key "$_wait")" in
        up)   ASK=1; ui_print "  keys   : (+) pressed - checking GitHub for a newer core" ;;
        down) ASK=0; ui_print "  keys   : (-) pressed - keeping the current core" ;;
        *)    ASK=0; ui_print "  keys   : no key pressed - keeping the current core" ;;
    esac
    flush_keys
    return 0
}

# Asked before anything is copied: the answer decides whether payload/bin/sing-box
# is kept or update-core replaces it. Always shown, so the keys are never a
# hidden feature.
ask_core_update

# Stop a previous instance before its binary is replaced. Both entry points are
# tried so an upgrade from the flat layout stops before it is moved.
if [ -x "$DATA/bin/pi-sing" ] || [ -x "$DATA/pi-sing" ]; then
    ui_print "  stopping running instance"
    if [ -x "$DATA/bin/pi-sing" ]; then
        "$DATA/bin/pi-sing" stop >/dev/null 2>&1
    else
        "$DATA/pi-sing" stop >/dev/null 2>&1
    fi
fi

mkdir -p "$DATA/bin" "$DATA/config" "$DATA/lists" "$DATA/run/log"

# v1.1.0 split the flat data dir into subdirectories. Move (not copy), so the old
# files disappear and cannot be started by mistake. A top-level entry point from
# v1.3.0 (symlink) or v1.4 (wrapper) is module-owned and removed above; the real
# file is in bin/ already.
migrate_flat() {
    _from="$1"; _to="$2"
    [ -e "$DATA/$_from" ] || [ -L "$DATA/$_from" ] || return 0
    if [ -L "$DATA/$_from" ]; then
        rm -f "$DATA/$_from"
        return 0
    fi
    if [ -e "$DATA/$_to" ]; then
        ui_print "  note  : $_to exists, left $_from alone"
        return 0
    fi
    case "$_to" in */*) mkdir -p "$DATA/${_to%/*}" || return 1 ;; esac
    mv -f "$DATA/$_from" "$DATA/$_to" || return 1
    ui_print "  moved : $_from -> $_to"
    return 0
}
if [ -x "$DATA/bin/pi-sing" ] || [ -L "$DATA/pi-sing" ]; then
    # v1.3.0 put symlinks here; v1.4 writes real wrapper files further down.
    # Either way the old entry point is module-owned, not user data, so it is
    # removed before the flat-layout migration and recreated at the end.
    rm -f "$DATA/pi-sing" "$DATA/pi.iptables" 2>/dev/null
fi

for _pair in \
    config.json:config/config.json \
    config.example.json:config/config.example.json \
    package.list.cfg:lists/package.list.cfg \
    ap.list.cfg:lists/ap.list.cfg \
    pi-sing:bin/pi-sing \
    pi.iptables:bin/pi.iptables \
    cache.db:run/cache.db; do
    migrate_flat "${_pair%%:*}" "${_pair#*:}" ||
        abort "! cannot move $DATA/${_pair%%:*}"
done

# Module scripts live in MODPATH; everything else is user data.
# KernelSU does not pre-extract module.prop, Magisk does: extract it here so the
# module is complete under both installers.
unzip -o "$ZIPFILE" 'module.prop' 'service.sh' 'action.sh' 'uninstall.sh' -d "$MODPATH" >&2 ||
    abort "! cannot extract module scripts"
mkdir -p "$TMPDIR/pising"
unzip -o "$ZIPFILE" 'payload/*' -d "$TMPDIR/pising" >&2 || abort "! cannot extract payload"
PAYLOAD="$TMPDIR/pising/payload"

# Replaced on every upgrade: the entry points and their licence.
ui_print "  update: bin/{pi-sing,pi.iptables,sing-box.LICENSE}"
for f in bin/pi-sing bin/pi.iptables bin/sing-box.LICENSE config/config.example.json; do
    cp -f "$PAYLOAD/$f" "$DATA/$f" || abort "! cannot install $f"
done

# Editable on the phone: never overwritten on upgrade.
for f in settings.ini config/config.json lists/package.list.cfg lists/ap.list.cfg; do
    if [ -f "$DATA/$f" ]; then
        ui_print "  keep  : $f"
    else
        cp -f "$PAYLOAD/$f" "$DATA/$f" || abort "! cannot create $DATA/$f"
        ui_print "  new   : $f"
    fi
done
# A v1.0.0 settings.ini has no path block, and the scripts refuse to guess. Append
# it instead of rewriting the file: existing values stay, the block is idempotent.
if ! grep -q '^bin_dir=' "$DATA/settings.ini"; then
    cat >> "$DATA/settings.ini" <<'PATHS'

# ------------------------------------------------ paths (added by installer v1.1.0)
# The data dir is split into subdirectories; these are derived from data_dir so
# the values above still own the absolute location.
bin_dir="${data_dir}/bin"
config_dir="${data_dir}/config"
list_dir="${data_dir}/lists"
run_dir="${data_dir}/run"
uid_file="${run_dir}/appuid.list"
PATHS
    ui_print "  update: settings.ini (path block for bin/, config/, lists/, run/)"
fi

# v1.3.0 has the directory block but no log_dir; pi-sing defaults it, appending it
# keeps settings.ini the one place the paths are written down.
if grep -q '^bin_dir=' "$DATA/settings.ini" && ! grep -q '^log_dir=' "$DATA/settings.ini"; then
    printf 'log_dir="${run_dir}/log"\n' >> "$DATA/settings.ini"
    ui_print "  update: settings.ini (log_dir)"
fi
# v1.3.0 has log.level in config.json only. The module owns the core's output
# file, so the level it writes there is a settings.ini knob now; the appended
# line is the same default the script uses.
if ! grep -q '^core_log_level=' "$DATA/settings.ini"; then
    printf '\n# Log level written into config.json at start ("config" = leave it).\ncore_log_level="warn"\n' >> "$DATA/settings.ini"
    ui_print "  update: settings.ini (core_log_level)"
fi

# services[].dashboard belongs to sing-box: the module does not resolve the path,
# rewrite the value, or move the directory. A relative path is resolved by the
# core against its own -D, and whatever it downloads stays where the config says.

# The release zip carries no core (79 MiB, and `update-core` follows the latest
# release anyway); an existing core is never touched. A zip that someone bundled
# one into still installs it. ASK=1 means "check GitHub", which update-core does
# with the sha256 from the release API and a `check` against the live config. A
# failed check/download keeps the installed core and never aborts the flash.
core_note() {
    ui_print "  core  : none installed"
    ui_print "  next  : su -c $DATA/bin/pi-sing update-core   (then: ... start)"
}
if [ -f "$PAYLOAD/bin/sing-box" ]; then
    cp -f "$PAYLOAD/bin/sing-box" "$DATA/bin/sing-box" || abort "! cannot install bin/sing-box"
    chmod 755 "$DATA/bin/sing-box" 2>/dev/null
    ui_print "  core  : bundled $("$DATA/bin/sing-box" version 2>/dev/null | head -n 1)"
elif [ -f "$DATA/bin/sing-box" ]; then
    chmod 755 "$DATA/bin/sing-box" 2>/dev/null
    ui_print "  core  : kept $("$DATA/bin/sing-box" version 2>/dev/null | head -n 1)"
fi
if [ "$ASK" = "1" ]; then
    ui_print "  core  : checking the latest sing-box release"
    if PISING_DIR="$DATA" PISING_QUIET=1 sh "$DATA/bin/pi-sing" update-core >> "$DATA/run/log/module.log" 2>&1 &&
       [ -x "$DATA/bin/sing-box" ]; then
        ui_print "  core  : $("$DATA/bin/sing-box" version 2>/dev/null | head -n 1)"
    else
        ui_print "  core  : update failed, keeping what is installed"
        tail -n 3 "$DATA/run/log/module.log" 2>/dev/null | while IFS= read -r _l; do
            ui_print "  | $_l"
        done
    fi
fi
[ -x "$DATA/bin/sing-box" ] || core_note

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm_recursive "$DATA" 0 0 0755 0644
set_perm "$DATA/bin/pi-sing" 0 0 0755
set_perm "$DATA/settings.ini" 0 0 0644
set_perm "$DATA/bin/pi.iptables" 0 0 0755
[ -f "$DATA/bin/sing-box" ] && set_perm "$DATA/bin/sing-box" 0 0 0755
set_perm "$DATA/bin/sing-box.LICENSE" 0 0 0644

rm -rf "$TMPDIR/pising"

# The CLI is reachable as `pi-sing` / `pi.iptables` because the module ships them
# in system/bin, so the manager's magic mount (Magisk) or Hybrid Mount (KernelSU
# metamodule) overlays them next to the other system binaries. The files are
# symlinks to the real scripts in $DATA/bin, the way /data/adb/modules/droidspaces
# does it: the scripts stay in the data dir, where `update-core` and a plain
# reinstall can replace them without waiting for a reboot.
#
# An older version left real wrapper files at $DATA/pi-sing, $DATA/pi.iptables and
# /dev/pi-sing (a tmpfs, so it was rewritten by service.sh every boot). They are
# removed: one entry point, one place.
rm -f "$DATA/pi-sing" "$DATA/pi.iptables" /dev/pi-sing 2>/dev/null
mkdir -p "$MODPATH/system/bin" || abort "! cannot create system/bin in the module"
for _e in pi-sing pi.iptables; do
    rm -f "$MODPATH/system/bin/$_e"
    ln -s "$DATA/bin/$_e" "$MODPATH/system/bin/$_e" || abort "! cannot link system/bin/$_e"
done
ui_print "  entry points : /system/bin/{pi-sing,pi.iptables} -> $DATA/bin/ (after reboot)"

# The old layout wrote pi-sing.log (core + module lines), iptables.log and
# service.log; two of them duplicated stdout. run/log/{module,sing-box}.log is
# the whole story now.
rm -f "$DATA/run/pi-sing.log" "$DATA/run/pi-sing.log.1" \
      "$DATA/run/iptables.log" "$DATA/run/service.log" 2>/dev/null

# Describe the state now, so the manager card does not keep showing "running"
# for a core that the install just stopped.
_install_desc="⚪ Installed - reboot to start | sing-box + TPROXY"
for _prop in "$MODPATH/module.prop" /data/adb/modules/pi-sing/module.prop; do
    [ -f "$_prop" ] || continue
    sed -i "s#^description=.*#description=${_install_desc}#" "$_prop" 2>/dev/null
done

ui_print "  config       : $DATA/config/config.json (services[].dashboard is sing-box's)"
ui_print "  logs         : $DATA/run/log/{module,sing-box}.log"
ui_print "  start now    : su -c $DATA/bin/pi-sing start"
ui_print "  status       : su -c $DATA/bin/pi-sing status"
ui_print "  after reboot : su -c pi-sing status   (system/bin via the magic mount)"
ui_print " "
