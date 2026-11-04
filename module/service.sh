#!/system/bin/sh
# Pi-Sing boot service (Magisk/KernelSU/APatch late_start service).
# Starts after the system finished booting and a default route exists.
#
# There is no service.log: pi-sing writes one line per event to
# run/log/module.log, and the core writes to run/log/sing-box.log. This script
# only adds the three things that can happen before the CLI is reachable.
MODDIR=${0%/*}
DATA=/data/adb/pi-sing
LOG_DIR="${DATA}/run/log"

mkdir -p "$LOG_DIR" 2>/dev/null

log() {
    printf '%s [Info] [svc] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_DIR}/module.log" 2>/dev/null
}

# The CLI is reachable as `pi-sing` through /system/bin, which the manager's magic
# mount (Magisk) or Hybrid Mount (KernelSU metamodule) fills from the module's
# system/bin. Nothing to create at boot; a leftover /dev/pi-sing from v1.x is
# removed instead, so there is only one entry point.
rm -f /dev/pi-sing 2>/dev/null

[ -f "${DATA}/settings.ini" ] || exit 0
. "${DATA}/settings.ini"

if [ "$enabled" != "1" ]; then
    log "disabled via settings.ini enabled=0"
    "${DATA}/bin/pi-sing" mark "🔴 Disabled (enabled=0)" >/dev/null 2>&1
    exit 0
fi

(
    i=0
    while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$i" -lt 120 ]; do
        sleep 5
        i=$((i + 1))
    done

    i=0
    while ! ip route get 1.1.1.1 2>/dev/null | grep -q " dev "; do
        sleep 2
        i=$((i + 1))
        [ "$i" -gt 60 ] && break
    done

    PISING_QUIET=1 "${DATA}/bin/pi-sing" start
    if [ "$watchdog" = "1" ]; then
        PISING_QUIET=1 "${DATA}/bin/pi-sing" watchdog
    fi
) >/dev/null 2>&1 &
