#!/bin/bash
# Pi-Sing: the action button has to be able to leave a fail-closed state.
#
# Incident this locks down: `config.json` pointed at a dead outbound. `check`
# passed, the core started, the rules went in, the self-test failed on the
# proxied path — and the rules stayed (fail closed, by design). The core then
# died. From then on the phone had no internet and the action button only read
# `process : running`: it saw "stopped", ran `start` again, the rules were never
# removed, and the only way back was uninstalling the module (uninstall.sh runs
# `stop`) plus a reboot.
#
# A rule set that is still installed is "the proxy is on", even with no core:
# the button must stop. The module card must not claim 🟢 while the tunnel is
# unproven (the watchdog used to overwrite the 🟠 within one tick).
#
#   1. a failed proxied probe keeps the rules and says 🟠 Tunnel down
#   2. status reports the core and the rules separately
#   3. the action button turns a dead-core rule set OFF (one press)
#   3b. a start whose core dies while the probes run drops the rules itself
#   4. the action button starts again from a clean OFF
#   5. the watchdog does not repaint the card 🟢 over a failed self-test
#   6. a start whose self-test passes clears the marker and says 🟢
#
# Usage: tests/action-test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d /tmp/pising-action.XXXXXX)"
DATA="${TMP}/data"
MOD="${TMP}/mod"
FAKE="${TMP}/fakebin"
PASS=0
FAIL=0

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got '$1', want '$2')"; }
has() { grep -qF "$2" "$1" 2>/dev/null && ok "$3" || bad "$3 (missing '$2' in $1)"; }
hasnt() { grep -qF "$2" "$1" 2>/dev/null && bad "$3 ('$2' in $1)" || ok "$3"; }

cleanup() {
    PISING_DIR="$DATA" PATH="$FAKE:$PATH" sh "$DATA/bin/pi-sing" stop >/dev/null 2>&1
    # The watchdog is a loop that ignores SIGTERM (measured on the device), and
    # `cli watchdog &` backgrounds a subshell, so $! is not the loop itself.
    for _p in $(pgrep -f "$DATA/bin/pi-sing watchdog" 2>/dev/null); do
        kill -9 "$_p" 2>/dev/null
    done
    [ -n "${WPID:-}" ] && kill -9 "$WPID" 2>/dev/null
    [ "${FAIL:-1}" -eq 0 ] && rm -rf "$TMP" || printf '  ---- kept %s\n' "$TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------- sandbox
mkdir -p "$DATA/bin" "$DATA/config" "$DATA/lists" "$DATA/run" "$MOD" "$FAKE"
cp "${ROOT}/module/payload/bin/pi-sing" "$DATA/bin/pi-sing"
# action.sh runs "$DATA/bin/pi-sing" directly; /system/bin/sh is the device path.
sed -i '1s|^#!/system/bin/sh|#!/bin/sh|' "$DATA/bin/pi-sing"
chmod 755 "$DATA/bin/pi-sing"
cp "${ROOT}/module/payload/settings.ini" "$DATA/settings.ini"
cat >> "$DATA/settings.ini" <<'EOF'

# ------------------------------------------------ test overrides
selftest=1
watchdog=0
core_user="root"
core_group=""
core_gid=""
EOF

# The rule set is one marker file: `pi.iptables on|off` flips it and
# `iptables -t mangle -S` reports it, so nothing touches this host's firewall.
cat > "$DATA/bin/pi.iptables" <<EOF
#!/bin/sh
case "\$1" in
    on|renew) : > "${TMP}/rules.on" ;;
    off)      rm -f "${TMP}/rules.on" ;;
esac
exit 0
EOF
cat > "${FAKE}/iptables" <<EOF
#!/bin/sh
case " \$* " in
    *" -S OUTPUT "*)     [ -f "${TMP}/rules.on" ] && echo "-A OUTPUT -j PISING_LOCAL" ;;
    *" -S PREROUTING "*) [ -f "${TMP}/rules.on" ] && echo "-A PREROUTING -j PISING_EXT" ;;
esac
exit 0
EOF
# Probe 1 is the direct one (must work), probe 2 the proxied one (the tunnel).
# FAIL_PROXIED=1 -> probe 2 fails; 0 -> both pass.
cat > "${FAKE}/curl" <<EOF
#!/bin/sh
# Calls come in pairs per start: 1 = direct probe, 2 = proxied probe.
_n=\$(cat "${TMP}/curl.n" 2>/dev/null || echo 0)
_n=\$((_n + 1))
echo "\$_n" > "${TMP}/curl.n"
[ "\${FAIL_PROXIED:-1}" = "1" ] && [ \$((_n % 2)) -eq 0 ] && exit 7
exit 0
EOF
chmod 755 "$DATA/bin/pi.iptables" "${FAKE}/iptables" "${FAKE}/curl"

cat > "$DATA/bin/sing-box" <<'EOF'
#!/bin/sh
case "$1" in
    version) echo "sing-box version 9.9.9" ;;
    check)   exit 0 ;;
    run)     [ "$2" = "--help" ] && { echo "      --disable-color   disable color output"; exit 0; }
             while :; do sleep 0.5; done ;;
    *)       exit 0 ;;
esac
EOF
chmod 755 "$DATA/bin/sing-box"

printf '{\n  "log": { "level": "info" },\n  "inbounds": [ { "type": "tproxy", "tag": "tproxy-in", "listen": "127.0.0.1", "listen_port": 1536 } ],\n  "outbounds": [ { "type": "direct", "tag": "direct" } ],\n  "route": { "final": "direct" }\n}\n' \
    > "$DATA/config/config.json"
printf 'id=pi-sing\nname=Pi-Sing\nversion=v1.4.0\ndescription=test\n' > "$MOD/module.prop"

cli() { PATH="$FAKE:$PATH" PISING_DIR="$DATA" PISING_MOD_DIR="$MOD" PISING_QUIET=1 \
        sh "$DATA/bin/pi-sing" "$@"; }
act() { PATH="$FAKE:$PATH" PISING_DIR="$DATA" PISING_MOD_DIR="$MOD" \
        sh "${ROOT}/module/action.sh" "$@"; }
card() { grep '^description=' "$MOD/module.prop" | head -n 1; }
probes() { rm -f "${TMP}/curl.n"; }

# ------------------------------------------------------------------- cases
echo "== a failed proxied probe keeps the rules, the card says 🟠"
probes
cli start >/dev/null 2>&1
eq "$?" "1" "start reports the unproven tunnel"
[ -f "${TMP}/rules.on" ] && ok "rules stay installed (fail closed)" || bad "the rules were removed"
[ -f "$DATA/run/selftest.failed" ] && ok "the failed self-test is recorded" || bad "no selftest.failed marker"
eq "$(card)" "description=🟠 Tunnel down - tap to stop | sing-box + TPROXY blacklist, 1536" \
   "the card says the tunnel is down, not 🟢"

echo "== status reports the core and the rules separately"
cli status > "${TMP}/st.out" 2>&1
has "${TMP}/st.out" "process    : running" "status: the core is up"
has "${TMP}/st.out" "iptables   : hooked into mangle OUTPUT/PREROUTING" "status: both hooks are reported"

echo "== the core dies after the rules are in: the button turns it OFF"
kill -9 "$(cat "$DATA/run/pi-sing.pid")" 2>/dev/null
sleep 0.3
cli status > "${TMP}/st2.out" 2>&1
has "${TMP}/st2.out" "process    : stopped" "status: the core is gone"
has "${TMP}/st2.out" "iptables   : hooked" "status: the rules still capture traffic"
rm -f "$DATA/run/stopped"
act > "${TMP}/act.out" 2>&1
has "${TMP}/act.out" "🔴 stopping Pi-Sing" "the button stops instead of restarting"
has "${TMP}/act.out" "Pi-Sing is OFF" "the button ends OFF"
hasnt "${TMP}/act.out" "🟢 starting Pi-Sing" "the button does not start from a dead-core rule set"
[ -f "${TMP}/rules.on" ] && bad "the rules survived the button" || ok "the button removed the rules"
[ -f "$DATA/run/selftest.failed" ] && bad "the failed self-test survived the stop" || ok "stop clears the marker"
[ -f "$DATA/run/stopped" ] && ok "the stop intent is recorded, the watchdog stays down" || bad "no stop intent"

echo "== from a clean OFF the same button starts"
act > "${TMP}/act2.out" 2>&1
has "${TMP}/act2.out" "🟢 starting Pi-Sing" "the button starts from OFF"
has "${TMP}/act2.out" "Pi-Sing is ON" "the button ends ON"
[ -f "${TMP}/rules.on" ] && ok "the start re-installed the rules" || bad "no rules after start"
eq "$(card)" "description=🟠 Tunnel down - tap to stop | sing-box + TPROXY blacklist, 1536" \
   "a start that cannot prove the tunnel is not announced as 🟢"

echo "== the watchdog does not repaint the card 🟢 over a failed self-test"
[ -f "$DATA/run/selftest.failed" ] || bad "no marker before the watchdog check"
sed -i 's/^watchdog=.*/watchdog=1/; s/^watchdog_interval=.*/watchdog_interval=1/' "$DATA/settings.ini"
cli watchdog >/dev/null 2>&1 &
WPID=$!
sleep 1
# The loop, not the subshell that started it: otherwise it keeps restarting the
# core through the rest of the test.
WPID="$(pgrep -f "$DATA/bin/pi-sing watchdog" 2>/dev/null | head -n 1)"
sleep 1.5
eq "$(card)" "description=🟠 Tunnel down - tap to stop | sing-box + TPROXY blacklist, 1536" \
   "the watchdog tick keeps the 🟠 state"
kill -9 "$WPID" 2>/dev/null
sleep 0.2
WPID=""
sed -i 's/^watchdog=.*/watchdog=0/; s/^watchdog_interval=.*/watchdog_interval=30/' "$DATA/settings.ini"

echo "== a start whose self-test passes says 🟢 and clears the marker"
FAIL_PROXIED=0 cli restart >/dev/null 2>&1
eq "$?" "0" "restart succeeds when both probes pass"
[ -f "$DATA/run/selftest.failed" ] && bad "the marker survived a passing self-test" || ok "the passing self-test cleared the marker"
eq "$(card)" "description=🟢 Running (pid $(cat "$DATA/run/pi-sing.pid")) | sing-box + TPROXY blacklist, 1536" \
   "the card is 🟢 after a passing self-test"

echo "== a stale verdict is not carried into the next start"
# run/selftest.failed from the previous attempt must not paint the card 🟠 when
# this start proves the tunnel: the measured bug was a card that stayed
# "🟠 Tunnel down" after a fully successful start (the marker was read before
# the probes ran and nothing repainted it).
: > "$DATA/run/selftest.failed"
kill -9 "$(cat "$DATA/run/pi-sing.pid")" 2>/dev/null
sleep 0.3
FAIL_PROXIED=0 cli start >/dev/null 2>&1
eq "$?" "0" "the fresh start passes"
eq "$(card)" "description=🟢 Running (pid $(cat "$DATA/run/pi-sing.pid")) | sing-box + TPROXY blacklist, 1536" \
   "the card is 🟢, not the previous 🟠"
[ -f "$DATA/run/selftest.failed" ] && bad "the old verdict survived" || ok "the old verdict is gone"

echo "== a config that logs to a file gets a warning"
# check passes with log.output, run dies (measured with a box_for_magisk config
# pointing at /data/adb/box/run/sing-box.log). The module does not edit the
# config, but it says what is wrong before the core starts.
write_cfg_output() {
    # core_log_level has rewritten "level" by now, so match the log line itself
    sed -i '/"log": {/ s#"level": "[a-z]*"#"level": "warn", "output": "/data/adb/box/run/sing-box.log"#' \
        "$DATA/config/config.json"
    grep -q '"output"' "$DATA/config/config.json" || bad "the test config has no log.output"
}
write_cfg_output
cli stop >/dev/null 2>&1          # the warning is printed by a real start
FAIL_PROXIED=0 cli start >/dev/null 2>&1
has "$DATA/run/log/module.log" "log.output is set" "log.output is reported before the start"

echo "== a core that dies while the probes run takes the rules with it"
# The rules must never outlive the core (box_for_magisk: no pid -> iptables
# disable): a captured packet with nobody listening is a phone with no internet.
cli stop >/dev/null 2>&1
rm -f "$DATA/run/stopped"
cat > "$DATA/bin/sing-box" <<'EOF'
#!/bin/sh
case "$1" in
    version) echo "sing-box version 9.9.9" ;;
    check)   exit 0 ;;
    run)     sleep 0.7; exit 1 ;;   # dies after the rules are in, before the probe
    *)       exit 0 ;;
esac
EOF
chmod 755 "$DATA/bin/sing-box"
probes
cli start >/dev/null 2>&1
eq "$?" "1" "start reports the failure"
[ -f "${TMP}/rules.on" ] && bad "the rules outlived the core" || ok "the rules were dropped with the core"
eq "$(card)" "description=🔴 Stopped - tunnel down | sing-box + TPROXY blacklist, 1536" \
   "the card says the proxy is off, not that it is running"
has "$DATA/run/log/module.log" "removing the TPROXY rules so the phone keeps its connection" \
   "the reason is in module.log"

echo "== a status with half the rule set installed still counts as hooked"
rm -f "${TMP}/rules.on"
cat > "${FAKE}/iptables" <<EOF
#!/bin/sh
case " \$* " in
    *" -S PREROUTING "*) echo "-A PREROUTING -j PISING_EXT" ;;
esac
exit 0
EOF
cli status > "${TMP}/st3.out" 2>&1
has "${TMP}/st3.out" "iptables   : hooked into mangle PREROUTING only" "a PREROUTING-only leftover is visible"
act >/dev/null 2>&1
[ -f "$DATA/run/stopped" ] && ok "the button cleaned it up" || bad "the button started instead of cleaning up"

echo
[ "$FAIL" -eq 0 ] && echo "action test: pass ($PASS checks)" ||
    { echo "action test: ${FAIL} failure(s)"; exit 1; }
