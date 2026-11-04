#!/system/bin/sh
# Pi-Sing uninstall: remove rules, stop sing-box, delete user data.
DATA=/data/adb/pi-sing

if [ -x "${DATA}/pi-sing" ]; then
    "${DATA}/pi-sing" stop >/dev/null 2>&1
fi
if [ -x "${DATA}/pi.iptables" ]; then
    "${DATA}/pi.iptables" off >/dev/null 2>&1
fi

rm -f /dev/pi-sing
rm -rf "$DATA"
