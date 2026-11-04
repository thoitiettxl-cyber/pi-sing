#!/bin/bash
# pi-sing CLI behaviour that does not need a device or a real core
# (dashboard path, log split/rotation, module description).
#
# The core is a shell stub: version/check/run, and `run` stays up until it is
# killed. pi.iptables is a no-op so the test never edits the host's rules.
#
#   1. dashboard "ui" is resolved next to config.json, not against -D run/
#   2. dashboard object {"path": ...} is resolved the same way
#   3. an absolute dashboard path is left alone
#   4. core_log_level overrides log.level in config.json ("config" leaves it)
#   5. module.prop says 🟢 running / 🔴 stopped, and only changes when it changes
#   6. module.log and sing-box.log stay separate; the core log rotates per start
#   7. `pi-sing log` and `pi-sing log core` read the two files
#   8. module.log rotates at 256 KiB
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
echo "== dashboard next to config.json"
write_config '"ui"'
cli start >/dev/null 2>&1
eq "$(grep -o '"dashboard": "[^"]*"' "$DATA/config/config.json")" \
   "\"dashboard\": \"${DATA}/config/ui\"" "relative \"ui\" -> config/ui"
has "$DATA/run/log/module.log" "dashboard: ui -> ${DATA}/config/ui" "the change is logged"
hasnt "$DATA/run/log/module.log" "+0700" "no core line in module.log"
has "$DATA/run/log/sing-box.log" "start ==" "the core log has its run header"
eq "$(grep '^description=' "$MOD/module.prop" | head -n1)" \
   "description=🟢 Running (pid $(cat "$DATA/run/pi-sing.pid")) | sing-box + TPROXY blacklist, 1536" \
   "module.prop shows the running pid"
cli status | grep -q "dashboard  : ${DATA}/config/ui" && ok "status prints the dashboard path" ||
    bad "status does not print the dashboard path"

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

echo "== dashboard as an object and as an absolute path"
reset
write_config '{ "path": "dash2", "update_interval": "24h" }'
cli start >/dev/null 2>&1
eq "$(grep -o '"path": "[^"]*"' "$DATA/config/config.json")" \
   "\"path\": \"${DATA}/config/dash2\"" "object path -> config/dash2"
reset
write_config "\"${TMP}/ui-abs\""
cli start >/dev/null 2>&1
has "$DATA/config/config.json" "\"dashboard\": \"${TMP}/ui-abs\"" "absolute path untouched"
hasnt "$DATA/run/log/module.log" "dashboard: " "an absolute path needs no rewrite (no log line)"

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
