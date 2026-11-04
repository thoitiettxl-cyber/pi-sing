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
# TTY, so the answer comes from the volume keys. `getevent -lqc 1` blocks until
# one event, so `timeout 1` around it is a bounded wait; /dev/input is not
# readable in every installer context, and then the default (keep) is taken
# instead of hanging. The flash itself never fails because of this.
read_volume_key() {  # $1 = seconds to wait -> "up" | "down" | nothing
    _left="$1"
    while [ "$_left" -gt 0 ]; do
        _ev="$(timeout 1 getevent -lqc 1 2>/dev/null)"
        case "$_ev" in
            *KEY_VOLUMEUP*) printf 'up'; return 0 ;;
            *KEY_VOLUMEDOWN*) printf 'down'; return 0 ;;
        esac
        _left=$((_left - 1))
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
    ui_print " "
    ui_print "  Volume keys (15 s):"
    ui_print "    (+) UP   = download the latest sing-box core from GitHub"
    ui_print "    (-) DOWN = keep the core in this zip / already on the phone"
    ui_print "    no key   = keep"
    if ! command -v getevent >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        ui_print "  keys   : no key input here, keeping the current core"
        return 0
    fi
    case "$(read_volume_key 15)" in
        up)   ASK=1; ui_print "  keys   : (+) pressed - checking GitHub for a newer core" ;;
        down) ASK=0; ui_print "  keys   : (-) pressed - keeping the current core" ;;
        *)    ASK=0; ui_print "  keys   : no key pressed - keeping the current core" ;;
    esac
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

# sing-box creates the dashboard inside the directory named by
# services[].dashboard. Before this version that was run/ (the core's -D), so a
# relative "dashboard": "ui" left the files in run/ui. The path is now resolved
# next to config.json, so move the managed copy once instead of downloading it
# again. An absolute or different path in config.json is left exactly as it is.
_dash_rel="$(sed -n 's/.*"dashboard"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$DATA/config/config.json" 2>/dev/null | head -n 1)"
if [ -z "$_dash_rel" ]; then
    _dash_rel="$(sed -n '/"dashboard"[[:space:]]*:[[:space:]]*{/,/}/s/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$DATA/config/config.json" 2>/dev/null | head -n 1)"
fi
if [ "$_dash_rel" = "ui" ] && [ ! -e "$DATA/config/ui" ]; then
    for _src in "$DATA/run/ui" "$DATA/ui"; do
        [ -d "$_src" ] || continue
        if mv -f "$_src" "$DATA/config/ui" 2>/dev/null; then
            ui_print "  moved : ${_src#"$DATA"/} -> config/ui"
        fi
        break
    done
fi
# A leftover managed copy in run/ is not read any more (a relative "ui" now
# means config/ui) and the dashboard is ~8 MB, so it is not left behind.
if [ "$_dash_rel" = "ui" ] && [ -d "$DATA/config/ui" ] && [ -d "$DATA/run/ui" ]; then
    rm -rf "$DATA/run/ui" && ui_print "  removed: stale run/ui (dashboard is config/ui)"
fi

# The core is the only big file. A thin zip carries none and an existing core is
# never touched; ASK=1 means "check GitHub", which update-core does with the
# sha256 from the release API and a `check` against the live config. A failed
# check/download keeps the bundled or installed core and never aborts the flash.
core_note() {
    ui_print "  core  : none installed"
    ui_print "  next  : su -c /dev/pi-sing update-core   (then: su -c /dev/pi-sing start)"
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

# The manager stages a module update and applies its boot scripts only on the
# next boot. Until then the previous service.sh/action.sh are what run, and they
# call $DATA/pi-sing, so that entry point has to exist now. It is a real wrapper
# file, not a symlink: a copy/backup that drops links then leaves a working
# path, and `ls -l` shows a script.
write_entry() {  # $1 = pi-sing | pi.iptables
    rm -f "$DATA/$1"
    {
        printf '#!/system/bin/sh\n'
        printf '# Generated by the Pi-Sing installer; the real script is bin/%s.\n' "$1"
        printf 'exec %s/bin/%s "$@"\n' "$DATA" "$1"
    } > "$DATA/$1" || abort "! cannot write $DATA/$1"
    chmod 755 "$DATA/$1"
}
write_entry pi-sing
write_entry pi.iptables

# /dev is a tmpfs and empty after a reboot; service.sh recreates this file. The
# rm is not cosmetic: v1.3.0 left a symlink here and writing through it would
# overwrite bin/pi-sing with the wrapper.
DEV_SHORTCUT=/dev/pi-sing
rm -f "$DEV_SHORTCUT" 2>/dev/null
{
    printf '#!/system/bin/sh\nexec %s/bin/pi-sing "$@"\n' "$DATA"
} > "$DEV_SHORTCUT" 2>/dev/null && chmod 755 "$DEV_SHORTCUT" 2>/dev/null

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

ui_print "  config       : $DATA/config/config.json"
ui_print "  dashboard    : $DATA/config/ui (relative path in config.json)"
ui_print "  logs         : $DATA/run/log/{module,sing-box}.log"
ui_print "  start now    : su -c /dev/pi-sing start"
ui_print "  status       : su -c /dev/pi-sing status"
ui_print " "
