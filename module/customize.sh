#!/system/bin/sh
# Pi-Sing installer (Magisk / KernelSU / APatch).
# The zip is not fully extracted by Magisk: this script decides what goes where.
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
mkdir -p "$DATA/bin" "$DATA/run"

# Stop a previous instance before its binary is replaced.
if [ -x "$DATA/pi-sing" ]; then
    ui_print "  stopping running instance"
    "$DATA/pi-sing" stop >/dev/null 2>&1
fi

# Module scripts live in MODPATH; everything else is user data.
# KernelSU does not pre-extract module.prop, Magisk does: extract it here so the
# module is complete under both installers.
unzip -o "$ZIPFILE" 'module.prop' 'service.sh' 'action.sh' 'uninstall.sh' -d "$MODPATH" >&2 ||
    abort "! cannot extract module scripts"
mkdir -p "$TMPDIR/pising"
unzip -o "$ZIPFILE" 'payload/*' -d "$TMPDIR/pising" >&2 || abort "! cannot extract payload"
PAYLOAD="$TMPDIR/pising/payload"

# Configuration is never overwritten on upgrade.
for f in settings.ini config.json package.list.cfg ap.list.cfg; do
    if [ -f "$DATA/$f" ]; then
        ui_print "  keep  : $f"
    else
        cp -f "$PAYLOAD/$f" "$DATA/$f" || abort "! cannot create $DATA/$f"
        ui_print "  new   : $f"
    fi
done
cp -f "$PAYLOAD/config.example.json" "$DATA/config.example.json"

ui_print "  update: pi-sing, pi.iptables"
cp -f "$PAYLOAD/pi-sing" "$DATA/pi-sing" || abort "! cannot install pi-sing"
cp -f "$PAYLOAD/pi.iptables" "$DATA/pi.iptables" || abort "! cannot install pi.iptables"

ui_print "  update: bin/sing-box"
cp -f "$PAYLOAD/bin/sing-box" "$DATA/bin/sing-box" || abort "! cannot install sing-box binary"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm_recursive "$DATA" 0 0 0755 0644
set_perm_recursive "$DATA/bin" 0 0 0755 0755
set_perm "$DATA/pi-sing" 0 0 0755
set_perm "$DATA/pi.iptables" 0 0 0755
set_perm "$DATA/settings.ini" 0 0 0644

rm -rf "$TMPDIR/pising"
ln -sf "$DATA/pi-sing" /dev/pi-sing 2>/dev/null
ui_print "  shortcut     : /dev/pi-sing"
ui_print "  config       : $DATA/config.json"
ui_print "  settings     : $DATA/settings.ini"
ui_print "  reboot to start (service.sh), then check: su -c /dev/pi-sing status"
ui_print " "
