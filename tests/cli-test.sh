#!/bin/bash
# pi-sing CLI behaviour that does not need a device or a real core
# (dashboard path, log split/rotation, module description).
#
# The core is a shell stub: version/check/run, and `run` stays up until it is
# killed. pi.iptables is a no-op so the test never edits the host's rules.
#
#   1. services[].dashboard is left exactly as written (sing-box owns that path)
#   2. core_log_level overrides log.level in config.json ("config" leaves it)
#   3. module.prop says 🟢 running / 🔴 stopped, and only changes when it changes
#   4. module.log and sing-box.log stay separate; the core log rotates per start
#   5. `pi-sing log` and `pi-sing log core` read the two files
#   6. module.log rotates at 256 KiB
#
# Usage: tests/cli-test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d /tmp/pising-cli.XXXXXX)"
DATA="${TMP}/data"
MOD="${TMP}/mod"
PASS=0
FAIL=0

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got '$1', want '$2')"; }
has() { grep -qF "$2" "$1" 2>/dev/null && ok "$3" || bad "$3 (missing '$2' in $1)"; }
hasnt() { grep -qF "$2" "$1" 2>/dev/null && bad "$3 ('$2' in $1)" || ok "$3"; }

cleanup() {
    PISING_DIR="$DATA" sh "$DATA/bin/pi-sing" stop >/dev/null 2>&1
    [ "${FAIL:-1}" -eq 0 ] && rm -rf "$TMP" || printf '  ---- kept %s\n' "$TMP"
}
trap cleanup EXIT

cli() {  # CLI with the test's data dir and a module.prop to write
    PATH="${TMP}/fakebin:$PATH" PISING_DIR="$DATA" PISING_MOD_DIR="$MOD" PISING_QUIET=1 \
        sh "$DATA/bin/pi-sing" "$@"
}

write_config() {  # $1 = dashboard JSON value (empty = no dashboard key)
    {
        printf '{\n'
        printf '  "log": { "level": "%s", "timestamp": true },\n' "${LEVEL:-info}"
        printf '  "inbounds": [ { "type": "tproxy", "tag": "tproxy-in", "listen": "127.0.0.1", "listen_port": 1536 } ],\n'
        printf '  "outbounds": [ { "type": "direct", "tag": "direct" } ],\n'
        printf '  "route": { "final": "direct" },\n'
        if [ -n "${1:-}" ]; then
            printf '  "services": [ { "type": "api", "listen": "127.0.0.1", "listen_port": 9099, "dashboard": %s } ]\n' "$1"
        else
            printf '  "services": [ { "type": "api", "listen": "127.0.0.1", "listen_port": 9099 } ]\n'
        fi
        printf '}\n'
    } > "$DATA/config/config.json"
}

reset() {  # clean runtime state between cases
    cli stop >/dev/null 2>&1
    rm -rf "$DATA/run/log" "$DATA/run/core.gid" "$DATA/run/pi-sing.pid"
}

# ------------------------------------------------------------------ sandbox
mkdir -p "$DATA/bin" "$DATA/config" "$DATA/lists" "$DATA/run" "$MOD" "${TMP}/fakebin"
cp "${ROOT}/module/payload/bin/pi-sing" "$DATA/bin/pi-sing"
chmod 755 "$DATA/bin/pi-sing"
# The rule set is one marker file, and `iptables -S` reports it: the module card
# is derived from the real state, so a start without rules is not "running".
cat > "$DATA/bin/pi.iptables" <<EOF
#!/bin/sh
case "\$1" in
    on|renew) : > "${TMP}/rules.on" ;;
    off)      rm -f "${TMP}/rules.on" ;;
esac
exit 0
EOF
chmod 755 "$DATA/bin/pi.iptables"
cat > "${TMP}/fakebin/iptables" <<EOF
#!/bin/sh
case " \$* " in
    *" -S OUTPUT "*)     [ -f "${TMP}/rules.on" ] && echo "-A OUTPUT -j PISING_LOCAL" ;;
    *" -S PREROUTING "*) [ -f "${TMP}/rules.on" ] && echo "-A PREROUTING -j PISING_EXT" ;;
esac
exit 0
EOF
chmod 755 "${TMP}/fakebin/iptables"
cp "${ROOT}/module/payload/settings.ini" "$DATA/settings.ini"
cat >> "$DATA/settings.ini" <<'EOF'

# ------------------------------------------------ test overrides
selftest=0
watchdog=0
core_user="root"
core_group=""
core_gid=""
EOF
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
printf 'id=pi-sing\nname=Pi-Sing\nversion=v1.4.0\ndescription=test\n' > "$MOD/module.prop"

# --------------------------------------------------------------------- run
echo "== services[].dashboard belongs to sing-box, the module leaves it alone"
write_config '"ui"'
cli start >/dev/null 2>&1
eq "$(grep -o '"dashboard": "[^"]*"' "$DATA/config/config.json")" '"dashboard": "ui"' \
   "a relative dashboard value is not rewritten"
[ -e "$DATA/config/ui" ] && bad "the module created config/ui" || ok "the module creates no dashboard directory"
[ -d "$DATA/run/ui" ] && bad "the module created run/ui" || ok "the module creates no run/ui either"
hasnt "$DATA/run/log/module.log" "dashboard" "nothing about the dashboard is logged"
hasnt "$DATA/run/log/module.log" "+0700" "no core line in module.log"
has "$DATA/run/log/sing-box.log" "start ==" "the core log has its run header"
eq "$(grep '^description=' "$MOD/module.prop" | head -n1)" \
   "description=🟢 Running (pid $(cat "$DATA/run/pi-sing.pid")) | sing-box + TPROXY blacklist, 1536" \
   "module.prop shows the running pid"
cli status > "${TMP}/st-dash.out" 2>&1
hasnt "${TMP}/st-dash.out" "dashboard" "status prints nothing about the dashboard"

_MTIME="$(stat -c %Y "$MOD/module.prop")"
sleep 1
cli start >/dev/null 2>&1
eq "$(stat -c %Y "$MOD/module.prop")" "$_MTIME" "module.prop is not rewritten when the state is unchanged"

cli stop >/dev/null 2>&1
eq "$(grep '^description=' "$MOD/module.prop")" "description=🔴 Stopped | sing-box + TPROXY blacklist, 1536" \
   "module.prop shows stopped"
cli mark "🔴 Disabled (enabled=0)" >/dev/null 2>&1
eq "$(grep '^description=' "$MOD/module.prop")" "description=🔴 Disabled (enabled=0) | sing-box + TPROXY blacklist, 1536" \
   "mark sets an arbitrary state"

echo "== the object and absolute forms are untouched too"
reset
write_config '{ "path": "dash2", "update_interval": "24h" }'
cli start >/dev/null 2>&1
eq "$(grep -o '"path": "[^"]*"' "$DATA/config/config.json")" '"path": "dash2"' \
   "an object dashboard path is not rewritten"
reset
write_config "\"${TMP}/ui-abs\""
cli start >/dev/null 2>&1
has "$DATA/config/config.json" "\"dashboard\": \"${TMP}/ui-abs\"" "an absolute path is untouched"

echo "== core log level"
reset
LEVEL=info write_config '"ui"'
cli start >/dev/null 2>&1
eq "$(grep -o '"level": "[^"]*"' "$DATA/config/config.json" | head -n1)" '"level": "warn"' \
   "core_log_level=warn overrides config.json"
hasnt "$DATA/run/log/sing-box.log" "INFO" "a warn core writes no INFO lines"
reset
sed -i 's/^core_log_level=.*/core_log_level="config"/' "$DATA/settings.ini"
LEVEL=info write_config '"ui"'
cli start >/dev/null 2>&1
eq "$(grep -o '"level": "[^"]*"' "$DATA/config/config.json" | head -n1)" '"level": "info"' \
   "core_log_level=config leaves the file in charge"
sed -i 's/^core_log_level=.*/core_log_level="warn"/' "$DATA/settings.ini"

echo "== an upgraded settings.ini without core_log_level still gets the warn default"
reset
sed -i '/^core_log_level=/d' "$DATA/settings.ini"
LEVEL=info write_config '"ui"'
cli start >/dev/null 2>&1
eq "$(grep -o '"level": "[^"]*"' "$DATA/config/config.json" | head -n1)" '"level": "warn"' \
   "the script default applies when the key is missing"
printf 'core_log_level="warn"\n' >> "$DATA/settings.ini"

echo "== core log rotates per start, one previous run kept"
reset
LEVEL=info write_config '"ui"'
cli start >/dev/null 2>&1
[ -f "$DATA/run/log/sing-box.log" ] && ok "first run has a core log" || bad "no core log after start"
cli stop >/dev/null 2>&1
LEVEL=info write_config '"ui"'
cli start >/dev/null 2>&1
[ -f "$DATA/run/log/sing-box.log.1" ] && ok "the previous run is kept as .1" || bad "no .1 core log"
[ "$(grep -c 'start ==' "$DATA/run/log/sing-box.log")" -eq 1 ] && ok "the current core log starts with one header" ||
    bad "the current core log has the wrong number of headers"

echo "== log readers"
cli log 5 > "${TMP}/log.out" 2>&1
has "${TMP}/log.out" "[cli]" "pi-sing log reads module.log"
cli log core 5 > "${TMP}/logcore.out" 2>&1
has "${TMP}/logcore.out" "start ==" "pi-sing log core reads sing-box.log"
hasnt "${TMP}/logcore.out" "[cli]" "log core does not mix in module lines"

echo "== a user stop is not undone by the watchdog"
reset
sed -i 's/^watchdog_interval=.*/watchdog_interval=1/' "$DATA/settings.ini"
cli start >/dev/null 2>&1
cli watchdog >/dev/null 2>&1 &
WPID=$!
sleep 1
# `cli watchdog &` backgrounds a subshell; the loop itself is its child, and it
# ignores SIGTERM, so kill it by command line (same as the device notes).
WPID="$(pgrep -f "$DATA/bin/pi-sing watchdog" 2>/dev/null | head -n 1)"
cli stop >/dev/null 2>&1
sleep 3
cli status | grep -q '^process    : running' && bad "the watchdog restarted a user-stopped core" ||
    ok "the watchdog leaves a user-stopped core stopped"
[ -f "$DATA/run/stopped" ] && ok "the stop intent is recorded" || bad "no stop intent file"
cli start >/dev/null 2>&1
[ -f "$DATA/run/stopped" ] && bad "start did not clear the stop intent" || ok "start clears the stop intent"
kill -9 "$WPID" 2>/dev/null
for _p in $(pgrep -f "$DATA/bin/pi-sing watchdog" 2>/dev/null); do kill -9 "$_p" 2>/dev/null; done
sed -i 's/^watchdog_interval=.*/watchdog_interval=30/' "$DATA/settings.ini"

echo "== a start brings the watchdog back, and only one"
# Measured on the device 2026-11-05: the loop only ever started from service.sh,
# so a `pi-sing restart` left the phone without it (no v6enforce, no restart of a
# crashed core) until the next boot, and the wifi -> 4G leak test answered from
# the carrier's resolvers. `watchdog_alive` reads the loop's own pid AND its
# command line, because a recycled pid must not hide a dead loop.
wd_count() {
    _n=0
    for _p in /proc/[0-9]*; do
        tr '\0' ' ' < "$_p/cmdline" 2>/dev/null | grep -qF "$DATA/bin/pi-sing watchdog" && _n=$((_n + 1))
    done
    printf '%s' "$_n"
}
reset
sed -i 's/^watchdog=.*/watchdog=1/' "$DATA/settings.ini"
sed -i 's/^watchdog_interval=.*/watchdog_interval=1/' "$DATA/settings.ini"
cli start >/dev/null 2>&1
sleep 1
eq "$(wd_count)" "1" "a start starts the missing watchdog loop"
[ -f "$DATA/run/watchdog.pid" ] && ok "the loop records its pid" || bad "no run/watchdog.pid"
cli start >/dev/null 2>&1
sleep 1
eq "$(wd_count)" "1" "a second start does not start a second loop"
cli stop >/dev/null 2>&1
kill -9 "$(cat "$DATA/run/watchdog.pid" 2>/dev/null)" 2>/dev/null
sed -i 's/^watchdog=.*/watchdog=0/' "$DATA/settings.ini"
sed -i 's/^watchdog_interval=.*/watchdog_interval=30/' "$DATA/settings.ini"

echo "== a process that only mentions the core path is not the core"
echo "== a name lookup that fails while 1.1.1.1 works turns the card orange"
# Measured on the device: sing-box's DoH server had a detour through the tunnel,
# the tunnel came from the old uplink, and after WiFi connected every lookup was
# SERVFAIL while an IP literal still worked — apps then resolved through netd and
# the leak test answered from the ISP's resolvers. The rules must stay (that is a
# DNS problem, not a leak to close), but the card must not claim green.
reset
cat > "${TMP}/fakebin/curl" <<EOF
#!/bin/sh
case " \$* " in
    *gstatic*) exit 6 ;;   # a name: the resolver is down
esac
exit 0                     # every IP-literal probe passes
EOF
chmod 755 "${TMP}/fakebin/curl"
sed -i 's/^selftest=.*/selftest=1/' "$DATA/settings.ini"
LEVEL=info write_config '"ui"'
cli start >/dev/null 2>&1
[ -f "$DATA/run/dns.failed" ] && ok "the failing name lookup is recorded" || bad "dns.failed was not written"
grep -q 'DNS failing' "$MOD/module.prop" && ok "the card says DNS is failing, not green" ||
    bad "the card still claims green ($(grep '^description' "$MOD/module.prop"))"
[ -f "$TMP/rules.on" ] && ok "the rules stay installed (fail closed, no leak to open)" ||
    bad "a DNS failure dropped the rules"
printf '#!/bin/sh\nexit 0\n' > "${TMP}/fakebin/curl"   # resolver answers again
cli stop >/dev/null 2>&1
cli start >/dev/null 2>&1
[ -f "$DATA/run/dns.failed" ] && bad "a working resolver did not clear the flag" ||
    ok "a working resolver clears the flag"
grep -q 'Running' "$MOD/module.prop" && ok "the card is green again" || bad "the card did not go back to green"
rm -f "${TMP}/fakebin/curl"
sed -i 's/^selftest=.*/selftest=0/' "$DATA/settings.ini"

echo "== a process that only mentions the core path is not the core"
# Measured on the device: the container shares the phone's PID namespace, so a
# shell whose command line contained bin_path looked like a running core and
# `stop` killed it (the agent's own shell got SIGKILLed). Only an argv token
# together with the executable or argv[0]/argv[1] counts as the core.
reset
sh -c 'sleep 30' "$DATA/bin/sing-box" /tmp/decoy &
DECOY=$!
sleep 0.3
cli status > "${TMP}/decoy.out" 2>&1
has "${TMP}/decoy.out" "process    : stopped" "a decoy that mentions the path is not the core"
cli stop >/dev/null 2>&1
kill -0 "$DECOY" 2>/dev/null && ok "stop left the decoy alone" || bad "stop killed an unrelated process"
kill -9 "$DECOY" 2>/dev/null
wait "$DECOY" 2>/dev/null

echo "== module.log rotates at 256 KiB"
reset
mkdir -p "$DATA/run/log"
head -c 300000 /dev/zero | tr '\0' 'x' > "$DATA/run/log/module.log"
cli start >/dev/null 2>&1
[ -f "$DATA/run/log/module.log.1" ] && ok "module.log moved to .1" || bad "module.log did not rotate"
[ "$(wc -c < "$DATA/run/log/module.log")" -lt 1024 ] && ok "a fresh module.log was started" ||
    bad "module.log was not restarted after the rotation"

cli stop >/dev/null 2>&1

echo
[ "$FAIL" -eq 0 ] && echo "cli test: pass ($PASS checks)" ||
    { echo "cli test: ${FAIL} failure(s)"; exit 1; }
