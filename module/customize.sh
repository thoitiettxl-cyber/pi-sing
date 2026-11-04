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
        _cmd="$(tr '\0' ' ' < "$_entry/cmdline" 2>/dev/null)" || continue
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

mkdir -p "$DATA/bin" "$DATA/config" "$DATA/lists" "$DATA/run"

# v1.1.0 split the flat data dir into subdirectories. Move (not copy), so the old
# files disappear and cannot be started by mistake. A top-level pi-sing/pi.iptables
# symlink (created below for pre-reboot compatibility) is just dropped: the real
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

# Replaced on every upgrade: the entry points, the core and its licence.
ui_print "  update: bin/{pi-sing,pi.iptables,sing-box}"
for f in bin/pi-sing bin/pi.iptables bin/sing-box bin/sing-box.LICENSE config/config.example.json; do
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

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm_recursive "$DATA" 0 0 0755 0644
set_perm "$DATA/bin/pi-sing" 0 0 0755
set_perm "$DATA/settings.ini" 0 0 0644
set_perm "$DATA/bin/pi.iptables" 0 0 0755
set_perm "$DATA/bin/sing-box" 0 0 0755
set_perm "$DATA/bin/sing-box.LICENSE" 0 0 0644

rm -rf "$TMPDIR/pising"

# The manager stages a module update and applies its boot scripts only on the
# next boot. Until then the previous service.sh/action.sh are what run, and they
# call $DATA/pi-sing, so keep the old names pointing at the new files.
ln -sf "$DATA/bin/pi-sing" "$DATA/pi-sing"
ln -sf "$DATA/bin/pi.iptables" "$DATA/pi.iptables"
ln -sf "$DATA/bin/pi-sing" /dev/pi-sing 2>/dev/null
ui_print "  links        : pi-sing, pi.iptables -> bin/"
ui_print "  shortcut     : /dev/pi-sing"
ui_print "  config       : $DATA/config/config.json"
ui_print "  settings     : $DATA/settings.ini"
ui_print "  reboot to start (service.sh), then check: su -c /dev/pi-sing status"
ui_print " "
