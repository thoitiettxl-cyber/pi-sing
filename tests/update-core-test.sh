#!/bin/bash
# `pi-sing update-core` (Linux host, no device needed).
#
# The command talks to GitHub, so the test serves a fake release API and tarballs
# from a local HTTP server and points the CLI at it with PISING_UPDATE_API /
# PISING_UPDATE_DL / PISING_UPDATE_ARCH. The core itself is a shell stub: it only
# has to answer `version`, `check` and `run`, which is exactly what the update
# path uses. Each case mutates one thing the command is supposed to catch:
#   1. happy path    -> binary replaced, core restarted, scratch dir removed
#   2. same tag again -> "already on the latest core", nothing written
#   3. wrong digest  -> refused, previous binary untouched
#   4. `check` fails -> refused, previous binary untouched
#   5. new core dies -> previous binary restored and restarted
#   6. API error body -> refused early, the body stays in run/update for diagnosis
#
# Usage: tests/update-core-test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d /tmp/pising-upd.XXXXXX)"
DATA="${TMP}/data"
DOC="${TMP}/docroot"
PASS=0
FAIL=0
PORT=""
SRV=""

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got '$1', want '$2')"; }
has() { grep -qF "$2" "$1" && ok "$3" || bad "$3 (missing '$2' in $1)"; }

cleanup() {
    [ -n "$SRV" ] && kill "$SRV" 2>/dev/null
    for p in $(pidof sing-box 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    [ "${FAIL:-1}" -eq 0 ] && rm -rf "$TMP" || printf '  ---- kept %s\n' "$TMP"
}
trap cleanup EXIT

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (HTTP server)"; exit 1; }

# find_pid prefers pidof, and pidof matches /proc/<pid>/stat:comm. The stub core is
# a shell script, so its comm is "sh" and pidof cannot see it (the real core is an
# ELF, where comm is "sing-box"). Hide pidof from the CLI so it takes the
# `pgrep -f <bin_path>` branch, which is also a real code path on the device.
mkdir -p "${TMP}/path"
for _d in /usr/bin /bin /usr/sbin; do
    for _f in "$_d"/*; do
        _b="${_f##*/}"
        [ "$_b" = pidof ] && continue
        [ -e "${TMP}/path/${_b}" ] || ln -s "$_f" "${TMP}/path/${_b}"
    done
done
export PATH="${TMP}/path:/root/.pi/agent/intercepted-commands"

# --------------------------------------------------------------- the sandbox

# Stub core: `version`, `check`, and `run` are the only subcommands the update
# path calls. kind=ok runs forever, kind=crash exits immediately (a core that
# fails to stay up), kind=badcheck fails `check` only.
make_core() {  # $1 = path, $2 = version, $3 = kind
    cat > "$1" <<EOF
#!/bin/sh
case "\$1" in
    version) echo "sing-box version $2" ;;
    check)   [ "$3" = badcheck ] && { echo 'FATAL decode config: bad' >&2; exit 1; }; exit 0 ;;
    run)     [ "\$2" = "--help" ] && { echo "      --disable-color   disable color output"; exit 0; }
             [ "$3" = crash ] && exit 1
             while :; do sleep 0.5; done ;;
    *)       exit 0 ;;
esac
EOF
    chmod 755 "$1"
}

install_cli() {
    mkdir -p "$DATA/bin" "$DATA/config" "$DATA/lists" "$DATA/run"
    cp "${ROOT}/module/payload/settings.ini" "$DATA/settings.ini"
    cat >> "$DATA/settings.ini" <<'EOF'

# ------------------------------------------------ test overrides
selftest=0
watchdog=0
core_user="root"
core_group=""
core_gid=""
EOF
    cp "${ROOT}/module/payload/bin/pi-sing" "$DATA/bin/pi-sing"
    chmod 755 "$DATA/bin/pi-sing"
    # pi.iptables is real on the device; here it would edit the build host's
    # rules, so the CLI gets a no-op. The update path only needs "rules ok".
    printf '#!/bin/sh\nexit 0\n' > "$DATA/bin/pi.iptables"
    chmod 755 "$DATA/bin/pi.iptables"
    cat > "$DATA/config/config.json" <<'EOF'
{
  "inbounds": [
    { "type": "tproxy", "tag": "tproxy-in", "listen": "127.0.0.1", "listen_port": 1536 }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
    make_core "$DATA/bin/sing-box" "1.0.0" ok
}

# The CLI's shebang is /system/bin/sh, so it is started through sh here.
cli() {  # $1 = release json name, $2 = subcommand
    PISING_DIR="$DATA" \
    PISING_UPDATE_API="http://127.0.0.1:${PORT}/$1" \
    PISING_UPDATE_DL="http://127.0.0.1:${PORT}" \
    PISING_UPDATE_ARCH=arm64 \
        sh "$DATA/bin/pi-sing" "$2"
}

core_version() { "$DATA/bin/sing-box" version 2>/dev/null | awk '{ print $NF }'; }
core_running() { PISING_DIR="$DATA" sh "$DATA/bin/pi-sing" status 2>/dev/null | grep -q '^process    : running'; }

# Publish a fake release: tarball under v<tag>/, release json at /<name>.json.
publish() {  # $1 = tag (9.9.9), $2 = release json name, $3 = core kind, $4 = digest override
    _ver="$1"; _name="$2"; _kind="$3"; _dig="${4:-}"
    _stage="${TMP}/stage"
    rm -rf "$_stage"
    _dir="${_stage}/sing-box-${_ver}-android-arm64"
    mkdir -p "$_dir"
    make_core "$_dir/sing-box" "$_ver" "$_kind"
    printf 'GPL-3.0 stub\n' > "$_dir/LICENSE"
    mkdir -p "${DOC}/v${_ver}"
    tar -czf "${DOC}/v${_ver}/sing-box-${_ver}-android-arm64.tar.gz" -C "$_stage" \
        "sing-box-${_ver}-android-arm64"
    [ -n "$_dig" ] || _dig="$(sha256sum "${DOC}/v${_ver}/sing-box-${_ver}-android-arm64.tar.gz" |
        awk '{ print $1 }')"
    cat > "${DOC}/${_name}.json" <<EOF
{
  "tag_name": "v${_ver}",
  "assets": [
    {
      "name": "sing-box-${_ver}-android-arm64.tar.gz",
      "state": "uploaded",
      "digest": "sha256:${_dig}",
      "browser_download_url": "http://127.0.0.1/v${_ver}/sing-box-${_ver}-android-arm64.tar.gz"
    }
  ]
}
EOF
}

start_server() {
    mkdir -p "$DOC"
    PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
    python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DOC" >"${TMP}/server.log" 2>&1 &
    SRV=$!
    _n=0
    while [ "$_n" -lt 50 ]; do
        curl -fsS -m 2 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && return 0
        sleep 0.1
        _n=$((_n + 1))
    done
    echo "fake release server did not come up"; cat "${TMP}/server.log"; exit 1
}

# ------------------------------------------------------------------- run it

install_cli
start_server
PISING_DIR="$DATA" sh "$DATA/bin/pi-sing" start >"${TMP}/start.log" 2>&1
core_running && ok "stub core 1.0.0 running before the update" ||
    { bad "stub core did not start"; cat "${TMP}/start.log"; cat "${DATA}/run/log/module.log"; exit 1; }

echo "== update to the latest release"
publish 9.9.9 rel-latest ok
cli rel-latest.json update-core >"${TMP}/out1" 2>&1
eq "$?" 0 "update-core exits 0"
LOG="${DATA}/run/log/module.log"
has "$LOG" "update: sha256 ok" "digest from the API is verified"
has "$LOG" "update: core 1.0.0 -> 9.9.9 (android-arm64)" "log records the version change"
eq "$(core_version)" "9.9.9" "bin/sing-box is the new core"
eq "$(cat "${DATA}/bin/sing-box.LICENSE")" "GPL-3.0 stub" "LICENSE comes from the tarball"
[ -e "${DATA}/run/update" ] && bad "scratch dir run/update was left behind" ||
    ok "scratch dir run/update removed"
core_running && ok "core restarted on the new binary" || bad "core not running after the update"

echo "== same tag again"
_mtime_before="$(ls -l --time-style=+%s "${DATA}/bin/sing-box" | awk '{ print $6 }')"
sleep 1
cli rel-latest.json update-core >"${TMP}/out2" 2>&1
eq "$?" 0 "update-core exits 0"
has "$LOG" "update: already on the latest core (9.9.9)" "reports 'already latest'"
eq "$(ls -l --time-style=+%s "${DATA}/bin/sing-box" | awk '{ print $6 }')" "$_mtime_before" \
    "binary untouched"

echo "== digest mismatch"
publish 9.9.10 rel-badsum ok 0000000000000000000000000000000000000000000000000000000000000000
cli rel-badsum.json update-core >"${TMP}/out3" 2>&1
[ "$?" -ne 0 ] && ok "update-core fails on a bad digest" || bad "update-core accepted a bad digest"
has "$LOG" "update: sha256 mismatch for sing-box-9.9.10-android-arm64.tar.gz" "mismatch is reported"
eq "$(core_version)" "9.9.9" "previous binary kept"

echo "== the new core rejects the config"
publish 9.9.11 rel-badcheck badcheck
cli rel-badcheck.json update-core >"${TMP}/out4" 2>&1
[ "$?" -ne 0 ] && ok "update-core fails when check fails" || bad "update-core installed a core that rejects the config"
has "$LOG" "update: core 9.9.11 rejects ${DATA}/config/config.json" "check failure is reported"
eq "$(core_version)" "9.9.9" "previous binary kept"

echo "== the new core does not stay up"
publish 9.9.12 rel-crash crash
cli rel-crash.json update-core >"${TMP}/out5" 2>&1
[ "$?" -ne 0 ] && ok "update-core fails when the core dies" || bad "update-core kept a core that dies"
has "$LOG" "update: core 9.9.12 did not stay up, rolled back to 9.9.9" "rollback is reported"
eq "$(core_version)" "9.9.9" "previous binary restored"
core_running && ok "previous core restarted after the rollback" || bad "core not running after the rollback"

echo "== an API error body is kept for diagnosis"
printf '{"message": "API rate limit exceeded for 127.0.0.1"}\n' > "${DOC}/rel-err.json"
cli rel-err.json update-core >"${TMP}/out6" 2>&1
[ "$?" -ne 0 ] && ok "update-core fails when there is no tag_name" || bad "update-core accepted an error body"
has "$LOG" "no tag_name in the API response" "missing tag_name is reported"
has "${DATA}/run/update/release.json" "rate limit exceeded" "the API body is kept in run/update/release.json"
eq "$(core_version)" "9.9.9" "previous binary kept"

PISING_DIR="$DATA" sh "$DATA/bin/pi-sing" stop >/dev/null 2>&1

# A thin install ships no core, so the first update-core has nothing to back up
# and nothing to restore: it must simply install the release.
echo "== first core on a thin install (no previous binary)"
rm -f "$DATA/bin/sing-box"
publish 9.9.13 rel-first ok
cli rel-first.json update-core >"${TMP}/out7" 2>&1
eq "$?" 0 "update-core exits 0 with no current core"
has "$LOG" "update: no current core, installing 9.9.13 from scratch" "first install is reported"
eq "$(core_version)" "9.9.13" "bin/sing-box created from the release"
[ -e "${DATA}/run/update" ] && bad "scratch dir run/update was left behind" ||
    ok "scratch dir run/update removed"

echo
[ "$FAIL" -eq 0 ] && echo "update-core test: pass ($PASS checks)" ||
    { echo "update-core test: ${FAIL} failure(s)"; exit 1; }
