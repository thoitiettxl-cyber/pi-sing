#!/system/bin/sh
# Pi-Sing action button (Magisk/KernelSU app): toggle the proxy on/off.
# The last line is the state the module card now shows: 🟢 running / 🔴 stopped.
DATA=/data/adb/pi-sing
CLI="${DATA}/bin/pi-sing"

if [ ! -x "$CLI" ]; then
    echo "Pi-Sing is not installed (no $CLI)"
    exit 1
fi

if "$CLI" status 2>/dev/null | grep -q '^process    : running'; then
    echo "🔴 stopping Pi-Sing"
    "$CLI" stop
else
    echo "🟢 starting Pi-Sing"
    "$CLI" start
fi

echo ""
if "$CLI" status 2>/dev/null | grep -q '^process    : running'; then
    echo "Pi-Sing is ON"
else
    echo "Pi-Sing is OFF"
fi
echo ""
"$CLI" status
