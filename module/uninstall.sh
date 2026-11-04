#!/system/bin/sh
# Pi-Sing uninstall: remove rules, stop sing-box, delete user data.
DATA=/data/adb/pi-sing
CLI="${DATA}/bin/pi-sing"
RULES="${DATA}/bin/pi.iptables"

if [ -x "$CLI" ]; then
    "$CLI" stop >/dev/null 2>&1
fi
if [ -x "$RULES" ]; then
    "$RULES" off >/dev/null 2>&1
fi

rm -f /dev/pi-sing
rm -rf "$DATA"
