#!/bin/bash
# Pi-Sing end-to-end test in an isolated network namespace (Linux host).
#
# Verifies the parts that are testable without an Android device:
#   1. `pi-sing start` runs sing-box and installs the rules
#   2. TCP from an app reaches the internet through the tproxy inbound
#   3. UDP DNS is hijacked to sing-box (`hijack-dns`) and answered
#   4. a uid listed in blacklist mode bypasses the proxy
#   5. the core's own traffic (gid bypass) is not captured -> no loop
#   6. `pi-sing stop` removes every rule it added
#
# Requirements: root, iproute2, iptables, curl, python3, setpriv, xt_TPROXY.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="${HERE}/../module/payload"
SINGBOX_BIN="${SINGBOX_BIN:-/root/tmp/sbref/sing-box-1.14.4-linux-arm64/sing-box}"
CORE_GID=3005
NS="pising0"
HOST_VETH="vhost0"
NS_VETH="vns0"
SUBNET="10.99.0.0/24"
TMP="$(mktemp -d /tmp/pising-e2e.XXXXXX)"
DATA="${TMP}/data"
MOD_LOG="${DATA}/run/log/module.log"
CORE_LOG="${DATA}/run/log/sing-box.log"
PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '  ---- %s\n' "$1"; }
ns()   { ip netns exec "$NS" "$@"; }
count_inbound() { grep -c 'inbound connection to' "$CORE_LOG" 2>/dev/null; }

cleanup() {
    ip netns del "$NS" 2>/dev/null
    ip link del "$HOST_VETH" 2>/dev/null
    iptables -t nat -D POSTROUTING -s "$SUBNET" -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -i "$HOST_VETH" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -o "$HOST_VETH" -j ACCEPT 2>/dev/null
    pkill -x sing-box 2>/dev/null
    [ "${FAIL:-1}" -eq 0 ] && rm -rf "$TMP" || printf "  ---- kept %s\n" "$TMP"
}
trap cleanup EXIT

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -x "$SINGBOX_BIN" ] || { echo "missing sing-box binary: $SINGBOX_BIN"; exit 1; }

echo "== setup namespace"
pkill -x sing-box 2>/dev/null
ip netns del "$NS" 2>/dev/null
ip netns add "$NS" || exit 1
ip link add "$HOST_VETH" type veth peer name "$NS_VETH" || exit 1
ip link set "$NS_VETH" netns "$NS"
ip addr add 10.99.0.1/24 dev "$HOST_VETH"
ip link set "$HOST_VETH" up
ns ip addr add 10.99.0.2/24 dev "$NS_VETH"
ns ip link set "$NS_VETH" up
ns ip link set lo up
ns ip route add default via 10.99.0.1
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s "$SUBNET" -j MASQUERADE
iptables -I FORWARD -i "$HOST_VETH" -j ACCEPT
iptables -I FORWARD -o "$HOST_VETH" -j ACCEPT
ok "namespace ${NS} up, ${SUBNET} masqueraded"

echo "== payload"
mkdir -p "$DATA/bin" "$DATA/config" "$DATA/lists" "$DATA/run"
cp "$PAYLOAD/bin/pi-sing" "$PAYLOAD/bin/pi.iptables" "$DATA/bin/"
cp "$PAYLOAD/settings.ini" "$DATA/"
# The test reads connection lines from the core log, so do not let the module's
# warn default silence them here.
printf 'core_log_level="config"\n' >> "$DATA/settings.ini"
cp "$PAYLOAD/config/config.example.json" "$DATA/config/config.json"
cp "$PAYLOAD/lists/package.list.cfg" "$PAYLOAD/lists/ap.list.cfg" "$DATA/lists/"
cp "$SINGBOX_BIN" "$DATA/bin/sing-box"
# The payload targets Android (/system/bin/sh); point it at the host shell here.
sed -i '1s|.*|#!/bin/sh|' "$DATA/bin/pi-sing" "$DATA/bin/pi.iptables"
# Readable logs + a plain UDP resolver (DoH to 1.1.1.1 is blocked in CI/sandboxes).
python3 - "$DATA/config/config.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c['log']['level'] = 'info'
c['dns']['servers'] = [{"type": "udp", "tag": "dns-remote", "server": "100.100.100.100"},
                       {"type": "local", "tag": "dns-local"}]
json.dump(c, open(p, 'w'), indent=2)
PY
chmod +x "$DATA/bin/pi-sing" "$DATA/bin/pi.iptables" "$DATA/bin/sing-box"

echo "== start"
ns env PISING_DIR="$DATA" "$DATA/bin/pi-sing" start
[ $? -eq 0 ] && ok "pi-sing start" || bad "pi-sing start"
grep -q 'core runs as' "$MOD_LOG" && ok "core started with a dedicated gid ($(grep -o 'core runs as.*' "$MOD_LOG" | tail -1))" ||
    bad "core gid bypass not active"
ns env PISING_DIR="$DATA" "$DATA/bin/pi-sing" status | sed 's/^/  /'

echo "== TCP through tproxy"
BEFORE=$(count_inbound)
CODE=$(ns curl -sS -m 25 -o /dev/null -w '%{http_code}' https://example.com 2>"${TMP}/curl.err")
[ "$CODE" = "200" ] && ok "curl https://example.com -> 200" || { bad "curl -> ${CODE:-none}"; note "$(cat "${TMP}/curl.err")"; }
AFTER=$(count_inbound)
[ "$AFTER" -gt "$BEFORE" ] && ok "connection entered tproxy-in (+$((AFTER - BEFORE)) inbound)" || bad "no inbound connection logged"
[ $((AFTER - BEFORE)) -le 3 ] && ok "no capture loop (+$((AFTER - BEFORE)) tcp inbound for one request)" ||
    bad "possible loop: +$((AFTER - BEFORE)) tcp inbound connections for one request"

echo "== UDP DNS hijack"
ns python3 - > "${TMP}/dns.out" 2>&1 <<'PY'
import socket, struct, random
q = struct.pack('>HHHHHH', random.randint(1, 65535), 0x0100, 1, 0, 0, 0)
for part in b'example.com'.split(b'.'):
    q += bytes([len(part)]) + part
q += b'\x00' + struct.pack('>HH', 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(15)
s.sendto(q, ('192.0.2.53', 53))        # TEST-NET-1, unreachable: only the hijack can answer
d, src = s.recvfrom(4096)
flags = struct.unpack('>H', d[2:4])[0]
print('rcode=%d answers=%d src=%s' % (flags & 0xF, struct.unpack('>H', d[6:8])[0], src[0]))
PY
grep -q 'rcode=0' "${TMP}/dns.out" && ok "UDP/53 answered by sing-box ($(tr -d '\n' < "${TMP}/dns.out"))" ||
    { bad "UDP/53 hijack failed"; note "$(cat "${TMP}/dns.out")"; }

echo "== per-app blacklist"
if command -v setpriv >/dev/null 2>&1; then
    printf '12345\n' >> "$DATA/lists/package.list.cfg"
    ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1
    ns iptables -t mangle -S PISING_LOCAL | grep -q -- '--uid-owner 12345 -j RETURN' &&
        ok "uid 12345 returns before the mark rules" || bad "uid 12345 return rule missing"
    U1=$(count_inbound)
    ns setpriv --reuid=12345 --regid=12345 --clear-groups curl -sS -m 25 -o /dev/null https://example.com 2>"${TMP}/u.err"
    U2=$(count_inbound)
    [ "$U1" = "$U2" ] && ok "uid 12345 traffic stayed outside the proxy ($U1 -> $U2)" ||
        bad "uid 12345 traffic was proxied ($U1 -> $U2)"
else
    note "skipped (no setpriv)"
fi

echo "== per-app whitelist"
sed -i 's/^proxy_mode=.*/proxy_mode="whitelist"/' "$DATA/settings.ini"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1
ns iptables -t mangle -S PISING_LOCAL | grep -q -- '-p tcp -m owner --uid-owner 12345 -j MARK' &&
    ok "uid 12345 is marked in whitelist mode" || bad "whitelist mark rule missing"
ns iptables -t mangle -S PISING_LOCAL | grep -q -- '0.0.0.0/0.*MARK or 0x200000' &&
    bad "whitelist mode still marks every app" || ok "unlisted uids stay direct in whitelist mode"
sed -i 's/^proxy_mode=.*/proxy_mode="blacklist"/' "$DATA/settings.ini"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1

echo "== hotspot ingress: proxied, unless it is the uplink"
ns ip link add wlan2 type dummy 2>/dev/null
ns ip link set wlan2 up 2>/dev/null
printf 'allow wlan2\n' >> "$DATA/lists/ap.list.cfg"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1
ns iptables -t mangle -S PISING_EXT | grep -q -- '-i wlan2 -p tcp -j TPROXY' &&
    ok "hotspot interface wlan2 is captured" || bad "wlan2 rule missing"
ns iptables -t mangle -S PISING_EXT | grep -q -- '-i wlan2 -p udp -j TPROXY' &&
    ok "hotspot interface wlan2 is captured for udp too" || bad "wlan2 udp rule missing"
# Same interface as the uplink: the entry must be dropped again.
ns env PISING_DIR="$DATA" PISING_UPLINK_IF=wlan2 "$DATA/bin/pi.iptables" renew >/dev/null 2>&1
ns iptables -t mangle -S PISING_EXT | grep -q -- '-i wlan2' &&
    bad "the uplink interface was captured (traffic would loop)" ||
    ok "an entry matching the default-route interface is skipped"
grep -q '^wlan2$' "$DATA/run/ap.list" && bad "wlan2 kept in run/ap.list" || ok "run/ap.list dropped the uplink"
sed -i '/^allow wlan2$/d' "$DATA/lists/ap.list.cfg"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1

echo "== dry run prints the commands and touches nothing"
_dry_before="$(ns iptables -t mangle -S 2>/dev/null | md5sum)"
ns env PISING_DIR="$DATA" PISING_DRY_RUN=1 "$DATA/bin/pi.iptables" on >"${TMP}/dry.out" 2>&1
grep -q '\[dry-run\] iptables.*TPROXY' "${TMP}/dry.out" &&
    ok "PISING_DRY_RUN prints the TPROXY command it would run" || bad "dry run printed no TPROXY command"
[ "$_dry_before" = "$(ns iptables -t mangle -S 2>/dev/null | md5sum)" ] &&
    ok "a dry run left every rule and hook untouched" || bad "a dry run changed the rule set"

echo "== ipv6=disable turns the stack off and puts it back"
sed -i 's/^ipv6=.*/ipv6="disable"/' "$DATA/settings.ini"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1
[ "$(ns cat /proc/sys/net/ipv6/conf/vns0/disable_ipv6 2>/dev/null)" = "1" ] &&
    ok "IPv6 stack disabled on the interface inside the namespace" || bad "disable_ipv6 was not set"
[ "$(ns cat /proc/sys/net/ipv6/conf/lo/disable_ipv6 2>/dev/null)" = "0" ] &&
    ok "lo is left alone, ::1 keeps working" || bad "lo lost IPv6 too"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" off >/dev/null 2>&1
[ "$(ns cat /proc/sys/net/ipv6/conf/vns0/disable_ipv6 2>/dev/null)" = "0" ] &&
    ok "\`off\` restored the previous sysctl values" || bad "disable_ipv6 was not restored"
sed -i 's/^ipv6=.*/ipv6="block"/' "$DATA/settings.ini"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1

echo "== counters"
ns iptables -t mangle -L PISING_LOCAL -n -v 2>/dev/null | head -n 10 | sed 's/^/  /'

echo "== stop"
ns env PISING_DIR="$DATA" "$DATA/bin/pi-sing" stop
ns iptables -t mangle -S 2>/dev/null | grep -q PISING && bad "PISING chains left after stop" || ok "all PISING chains removed"
[ -z "$(ns ip rule show 2>/dev/null | grep -F 'lookup 2027')" ] && ok "ip rule removed" || bad "ip rule still present"
ns pidof sing-box >/dev/null 2>&1 && bad "sing-box still running" || ok "sing-box stopped"

echo
printf '==> %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
