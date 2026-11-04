#!/system/bin/sh
# Pi-Sing boot service (Magisk/KernelSU/APatch late_start service).
# Starts after the system finished booting and a default route exists.
MODDIR=${0%/*}
DATA=/data/adb/pi-sing
LOG="${DATA}/run/service.log"

mkdir -p "${DATA}/run" 2>/dev/null
[ -f "${DATA}/settings.ini" ] || exit 0
. "${DATA}/settings.ini"

if [ "$enabled" != "1" ]; then
    printf '%s [Info] disabled via settings.ini enabled=0\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
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

    "${DATA}/pi-sing" start
    if [ "$watchdog" = "1" ]; then
        "${DATA}/pi-sing" watchdog
    fi
) >> "$LOG" 2>&1 &
