#!/system/bin/sh
# Pi-Sing action button (Magisk/KernelSU app): toggle proxy on/off.
DATA=/data/adb/pi-sing

if [ ! -x "${DATA}/pi-sing" ]; then
    echo "Pi-Sing is not installed"
    exit 1
fi

if "${DATA}/pi-sing" status 2>/dev/null | grep -q '^process    : running'; then
    echo "stopping Pi-Sing"
    "${DATA}/pi-sing" stop
else
    echo "starting Pi-Sing"
    "${DATA}/pi-sing" start
fi

echo ""
"${DATA}/pi-sing" status
