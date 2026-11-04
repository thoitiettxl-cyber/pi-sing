#!/system/bin/sh
# Pi-Sing action button (Magisk/KernelSU app): toggle proxy on/off.
DATA=/data/adb/pi-sing
CLI="${DATA}/bin/pi-sing"

if [ ! -x "$CLI" ]; then
    echo "Pi-Sing is not installed"
    exit 1
fi

if "$CLI" status 2>/dev/null | grep -q '^process    : running'; then
    echo "stopping Pi-Sing"
    "$CLI" stop
else
    echo "starting Pi-Sing"
    "$CLI" start
fi

echo ""
"$CLI" status
