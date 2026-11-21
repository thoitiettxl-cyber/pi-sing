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
#   7. `renew` swaps the rule set in place: the hooks are there in every listing
#      taken while it runs, and ipv6=disable never switches IPv6 back on
#   8. a table that refuses its batch falls back to the rule-by-rule build
#   9. the tproxy port only answers TPROXY'd traffic (no self-dial loop)
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
eq()   { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got '$1', want '$2')"; }
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
# No watchdog: nothing here tests it, a loop that renews on its own would run
# between the assertions, and `start` leaves it behind when the test ends
# (measured 2026-11-21: five runs, five `pi-sing watchdog` loops still alive).
printf 'watchdog=0\n' >> "$DATA/settings.ini"
cp "$PAYLOAD/config/config.example.json" "$DATA/config/config.json"
cp "$PAYLOAD/lists/package.list.cfg" "$PAYLOAD/lists/ap.list.cfg" "$DATA/lists/"
cp "$SINGBOX_BIN" "$DATA/bin/sing-box"
# The payload targets Android (/system/bin/sh); point it at the host shell here.
sed -i '1s|.*|#!/bin/sh|' "$DATA/bin/pi-sing" "$DATA/bin/pi.iptables"
# Readable logs + a plain UDP resolver (DoH to 1.1.1.1 is blocked in CI/sandboxes).
# PISING_TEST_DNS names another one when this one does not answer: measured
# 2026-11-21 from this container (WiFi uplink) 100.100.100.100:53 timed out,
# and the curl and UDP/53 assertions then fail on a rule set that is fine
# (3 failures, on the previous commit too); 1.1.1.1 answered.
python3 - "$DATA/config/config.json" "${PISING_TEST_DNS:-100.100.100.100}" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c['log']['level'] = 'info'
c['dns']['servers'] = [{"type": "udp", "tag": "dns-remote", "server": sys.argv[2]},
                       {"type": "local", "tag": "dns-local"}]
json.dump(c, open(p, 'w'), indent=2)
PY
chmod +x "$DATA/bin/pi-sing" "$DATA/bin/pi.iptables" "$DATA/bin/sing-box"
# One connection (tcp) or one datagram (udp) to port 1536 of a host. tcp prints
# connected | timeout | refused; a dropped SYN is a timeout.
cat > "${TMP}/probe.py" <<'PY'
import socket, sys
kind, host = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_INET6 if ':' in host else socket.AF_INET,
                  socket.SOCK_STREAM if kind == 'tcp' else socket.SOCK_DGRAM)
s.settimeout(2)
try:
    s.connect((host, 1536))
    if kind == 'udp':
        s.send(b'x')
        print('sent')
    else:
        print('connected')
except ConnectionRefusedError:
    print('refused')
except socket.timeout:
    print('timeout')
except OSError as e:
    print(e.__class__.__name__)
PY

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

echo "== renew swaps the rule set in place"
# `renew` used to remove every rule and then build the set again, one iptables
# call per rule. Measured in module.log on the device (2026-11-16..21): the
# rules were gone for a median of 4 s per renew, 63 s at worst, 128 s a day,
# always right after the network changed; in a namespace like this one a poller
# found a hook missing in 350 of 572 listings. A table is one commit now.
hooks_now() {
    ns iptables -w 5 -t mangle -S 2>/dev/null |
        awk '/^-A OUTPUT -j PISING_LOCAL$/ { o++ } /^-A PREROUTING -j PISING_EXT$/ { p++ } END { print o + 0, p + 0 }'
}
rm -f "${TMP}/poll.stop"
( while [ ! -f "${TMP}/poll.stop" ]; do hooks_now; done > "${TMP}/poll.out" ) &
POLLER=$!
sleep 0.3
for _i in 1 2 3 4 5; do
    ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1
done
sleep 0.3
: > "${TMP}/poll.stop"
wait "$POLLER" 2>/dev/null
_samples="$(wc -l < "${TMP}/poll.out" | tr -d ' ')"
_gaps="$(grep -cv '^1 1$' "${TMP}/poll.out")"
[ "$_samples" -ge 20 ] && [ "$_gaps" -eq 0 ] &&
    ok "5 renews, ${_samples} listings of the table: both hooks in every one, once" ||
    bad "${_gaps} of ${_samples} listings saw a hook missing or doubled during a renew"
[ "$(ns ip rule show 2>/dev/null | grep -c 'lookup 2027')" = "1" ] &&
    ok "still one ip rule after the renews" || bad "the renews changed the number of ip rules"
# What two builders running into each other left on the device (2026-11-21:
# both hooks twice, PISING_EXT 74 rules for 23 distinct ones).
ns iptables -t mangle -I OUTPUT -j PISING_LOCAL
ns iptables -t mangle -I PREROUTING -j PISING_EXT
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1
[ "$(hooks_now)" = "1 1" ] && ok "a doubled hook is single again after one renew" ||
    bad "the hooks are not single after a renew ($(hooks_now))"
# A table that refuses its batch gets the rule-by-rule build, and the log says
# that the proxy was off meanwhile.
mkdir -p "${TMP}/norestore"
printf '#!/bin/sh\necho "iptables-restore: line 2 failed" >&2\nexit 1\n' > "${TMP}/norestore/iptables-restore"
chmod 755 "${TMP}/norestore/iptables-restore"
ns env PATH="${TMP}/norestore:$PATH" PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1
[ "$(hooks_now)" = "1 1" ] &&
    ns iptables -t mangle -S PISING_LOCAL | grep -q -- '-d 10.0.0.0/8 -j RETURN' &&
    ok "without iptables-restore the rule-by-rule build installs the set" ||
    bad "no rule set after a refused batch"
grep -q 'falling back to the rule-by-rule build' "$MOD_LOG" && ok "and the fallback is in module.log" ||
    bad "the fallback was silent"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1

echo "== intranet destinations stay direct (OUTPUT path)"
# The RETURNs must sit in PISING_LOCAL itself: a RETURN inside a chain that
# PISING_LOCAL jumps to only resumes in PISING_LOCAL, so the blanket MARK at the
# end of it caught the intranet packet anyway (measured on the device
# 2026-11-05: TCP to a LAN printer never left, conntrack SYN_SENT/UNREPLIED,
# and it connected the moment `pi-sing stop` ran).
ns iptables -t mangle -S PISING_LOCAL | grep -q -- '-d 10.0.0.0/8 -j RETURN' &&
    ok "intranet RETURN rules live in PISING_LOCAL" ||
    bad "intranet RETURN rules are missing from PISING_LOCAL"
ns iptables -t mangle -S PISING_LOCAL | grep -q -- '-j PISING_SKIP' &&
    bad "PISING_LOCAL jumps to a nested chain (its RETURN only resumes there)" ||
    ok "no nested-chain jump left in PISING_LOCAL"
mark_hits() {
    ns iptables -t mangle -vnxL PISING_LOCAL 2>/dev/null |
        awk '/MARK/ && /tcp/ && !/dpt:53/ { print $1 }' | tail -n 1
}
M1="$(mark_hits)"
ns python3 -c "import socket; s = socket.socket(); s.settimeout(2); s.connect(('10.99.0.1', 9100))" 2>/dev/null
sleep 1
M2="$(mark_hits)"
[ "${M1:-x}" = "${M2:-y}" ] && ok "a SYN to an intranet address was not marked (${M1})" ||
    bad "a SYN to an intranet address was marked (${M1} -> ${M2})"

echo "== a tailnet range is captured, not bypassed (tailnet4)"
# Measured on the device 2026-11-12: with 100.64.0.0/10 on both bypass lists a
# tailnet peer was unreachable from the phone and from the container while the
# peer's own handshake counters moved. Both halves have to move: the OUTPUT
# RETURN sent the packet out of the uplink, and the PREROUTING ACCEPT kept the
# answer from re-entering the tunnel.
ns iptables -t mangle -S PISING_LOCAL | grep -q -- '-d 100.64.0.0/10 -j RETURN' &&
    ok "100.64.0.0/10 is bypassed by default" || bad "the default bypass list changed"
printf '\ntailnet4="100.64.0.0/10"\n' >> "$DATA/settings.ini"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1
for _chk in PISING_LOCAL:RETURN PISING_BYPASS:ACCEPT; do
    _chain="${_chk%%:*}"; _verdict="${_chk##*:}"
    ns iptables -t mangle -S "$_chain" | grep -q -- "-d 100.64.0.0/10 -j ${_verdict}" &&
        bad "100.64.0.0/10 is still bypassed in ${_chain}" ||
        ok "100.64.0.0/10 left the bypass list of ${_chain}"
done
ns iptables -t mangle -S PISING_LOCAL | grep -q -- '-d 10.0.0.0/8 -j RETURN' &&
    ok "the other private ranges are still bypassed" || bad "tailnet4 removed more than its own range"
# Captured means the blanket MARK sees it: nothing RETURNs for it any more.
_tail_m1="$(ns iptables -t mangle -vnxL PISING_LOCAL 2>/dev/null | awk '/MARK/ && /tcp/ && !/dpt:53/ { print $1 }' | tail -n 1)"
ns python3 -c "import socket; s = socket.socket(); s.settimeout(2); s.connect(('100.64.0.1', 9100))" 2>/dev/null
sleep 1
_tail_m2="$(ns iptables -t mangle -vnxL PISING_LOCAL 2>/dev/null | awk '/MARK/ && /tcp/ && !/dpt:53/ { print $1 }' | tail -n 1)"
[ "${_tail_m1:-x}" != "${_tail_m2:-y}" ] &&
    ok "a SYN to the tailnet range was marked for the proxy (${_tail_m1} -> ${_tail_m2})" ||
    bad "a SYN to the tailnet range was not marked (${_tail_m1} -> ${_tail_m2})"
sed -i '/^tailnet4=/d' "$DATA/settings.ini"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1
ns iptables -t mangle -S PISING_LOCAL | grep -q -- '-d 100.64.0.0/10 -j RETURN' &&
    ok "clearing tailnet4 puts the range back on the bypass list" || bad "tailnet4 stayed applied after removal"
[ "${M1:-x}" = "${M2:-y}" ] && ok "a SYN to an intranet address was not marked (${M1})" ||
    bad "a SYN to an intranet address was marked (${M1} -> ${M2})"

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
[ "$(ns cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)" = "1" ] &&
    ok "the new-interface template is off too" || bad "conf/default/disable_ipv6 was not set"
# netd re-enables IPv6 on every network it brings up, and an interface created
# after `on` inherits the template (measured on the device: WiFi came up after
# the boot start, wlan0 got disable_ipv6=0 back, netd's resolver list held
# fe80::1%wlan0 and names left for the LAN router).
ns ip link add vns9 type dummy 2>/dev/null
ns ip link set vns9 up 2>/dev/null
[ "$(ns cat /proc/sys/net/ipv6/conf/vns9/disable_ipv6 2>/dev/null)" = "1" ] &&
    ok "an interface created after \`on\` comes up with IPv6 off" || bad "a new interface came up with IPv6 on"
ns sh -c 'echo 0 > /proc/sys/net/ipv6/conf/vns0/disable_ipv6' 2>/dev/null
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" v6enforce >/dev/null 2>&1
[ "$(ns cat /proc/sys/net/ipv6/conf/vns0/disable_ipv6 2>/dev/null)" = "1" ] &&
    ok "\`v6enforce\` switches IPv6 off again after netd turned it on" || bad "enforce left IPv6 on"
# A renew used to put the stack back before taking it away again: IPv6 was on
# for as long as the IPv4 rebuild took (62% of the samples in this poll).
rm -f "${TMP}/poll.stop"
ns sh -c "while [ ! -f '${TMP}/poll.stop' ]; do v=; read v < /proc/sys/net/ipv6/conf/vns0/disable_ipv6; echo \"\$v\"; done" \
    > "${TMP}/poll6.out" 2>/dev/null &
POLLER=$!
sleep 0.2
for _i in 1 2 3; do
    ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1
done
sleep 0.2
: > "${TMP}/poll.stop"
wait "$POLLER" 2>/dev/null
_samples="$(wc -l < "${TMP}/poll6.out" | tr -d ' ')"
_gaps="$(grep -c '^0$' "${TMP}/poll6.out")"
[ "$_samples" -ge 100 ] && [ "$_gaps" -eq 0 ] &&
    ok "3 renews in ipv6=disable, ${_samples} reads of disable_ipv6: never back on" ||
    bad "IPv6 was on in ${_gaps} of ${_samples} reads during a renew"
ns ip6tables -t mangle -S PISING_INPUT 2>/dev/null | grep -q -- '--dport 1536 -m mark ! --mark 0x200000/0x200000 -j DROP' &&
    ok "ipv6=disable still guards the tproxy port (::1 stays up)" ||
    bad "no IPv6 guard on the tproxy port in ipv6=disable"
U6=$(grep -c 'connection to \[::1\]:1536' "$CORE_LOG" 2>/dev/null)
eq "$(ns python3 "${TMP}/probe.py" tcp ::1)" "timeout" "[::1]:<tproxy port> gets no answer"
sleep 1
eq "$(grep -c 'connection to \[::1\]:1536' "$CORE_LOG" 2>/dev/null)" "$U6" "and never reaches the core"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" off >/dev/null 2>&1
[ "$(ns cat /proc/sys/net/ipv6/conf/vns0/disable_ipv6 2>/dev/null)" = "0" ] &&
    ok "\`off\` restored the previous sysctl values" || bad "disable_ipv6 was not restored"
[ "$(ns cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)" = "0" ] &&
    ok "\`off\` restored the new-interface template" || bad "conf/default/disable_ipv6 was not restored"
sed -i 's/^ipv6=.*/ipv6="block"/' "$DATA/settings.ini"
ns env PISING_DIR="$DATA" "$DATA/bin/pi.iptables" renew >/dev/null 2>&1

echo "== the tproxy port answers TPROXY'd traffic only"
# The inbound listens on every address, and a connection made to the port has
# the port itself as its destination: the core dials it, which is itself, and
# every dial is the next inbound connection. Measured 2026-11-21 with sing-box
# 1.14.4: one TCP connection from a LAN neighbour, held for 1 s, was ~30 s of
# looping (110 878 fds, 37.5 CPU-seconds), one UDP datagram 19 307 inbound
# packet connections in 5 s. PISING_INPUT, first in mangle INPUT, drops what
# gets to the port without the TPROXY mark (mangle has no REJECT, and behind
# netd's mangle INPUT chains the mark is no longer ours). The host end of the
# veth is this namespace's LAN neighbour.
ns iptables -t mangle -S PISING_INPUT 2>/dev/null | grep -q -- '-p tcp .*--dport 1536 -m mark ! --mark 0x200000/0x200000 -j DROP' &&
    ok "mangle INPUT drops unmarked tcp to the tproxy port" || bad "no tcp guard on the tproxy port"
ns iptables -t mangle -S PISING_INPUT 2>/dev/null | grep -q -- '-p udp .*--dport 1536 -m mark ! --mark 0x200000/0x200000 -j DROP' &&
    ok "and unmarked udp" || bad "no udp guard on the tproxy port"
[ "$(ns iptables -t mangle -S INPUT 2>/dev/null | sed -n 2p)" = "-A INPUT -j PISING_INPUT" ] &&
    ok "the guard is the first rule of mangle INPUT" || bad "the guard is not first in mangle INPUT"
ns ip6tables -t mangle -S PISING_INPUT 2>/dev/null | grep -q -- '--dport 1536 -m mark ! --mark 0x200000/0x200000 -j DROP' &&
    ok "the IPv6 side has the same guard" || bad "no IPv6 guard on the tproxy port"
G1=$(grep -c 'connection to 10.99.0.2:1536' "$CORE_LOG" 2>/dev/null)
eq "$(python3 "${TMP}/probe.py" tcp 10.99.0.2)" "timeout" "a LAN neighbour's tcp to <phone>:<tproxy port> gets no answer"
python3 "${TMP}/probe.py" udp 10.99.0.2 >/dev/null 2>&1
eq "$(ns python3 "${TMP}/probe.py" tcp 10.99.0.2)" "timeout" "an app on the phone gets none through the phone's own address"
sleep 1
eq "$(grep -c 'connection to 10.99.0.2:1536' "$CORE_LOG" 2>/dev/null)" "$G1" "neither of them, nor the neighbour's udp datagram, reached the core"
# A proxied connection to <somewhere>:<tproxy port> is not a connection to the
# listener: TPROXY marked it, and it has to pass.
eq "$(ns python3 "${TMP}/probe.py" tcp 1.1.1.1)" "connected" "a proxied connection to <host>:<tproxy port> is still accepted"
sleep 1
grep -q 'inbound connection to 1.1.1.1:1536' "$CORE_LOG" &&
    ok "and reaches the core with its real destination" ||
    bad "the guard also rejected a proxied connection to port 1536"

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
