#!/system/bin/sh
# Pi-Sing action button (Magisk/KernelSU app): toggle the proxy on/off.
# The last line is the state the module card now shows: 🟢 running / 🔴 stopped.
#
# A start that cannot prove the tunnel leaves the TPROXY rules installed (fail
# closed, no leak) and the core may die afterwards. Rules without a core is
# still "the proxy is on", and the button has to be able to leave it: deciding
# on the process alone made the next press start the core again, so the phone
# stayed offline and only uninstalling the module brought the connection back.
DATA="${PISING_DIR:-/data/adb/pi-sing}"
CLI="${DATA}/bin/pi-sing"

if [ ! -x "$CLI" ]; then
    echo "Pi-Sing is not installed (no $CLI)"
    exit 1
fi

# One `pi-sing status` (it runs the core binary for its version, twice) decides
# both halves of the state.
snapshot() {
    _out="$("$CLI" status 2>/dev/null)"
    _running=0
    _hooked=0
    case "$_out" in *"process    : running"*) _running=1 ;; esac
    case "$_out" in *"iptables   : hooked"*) _hooked=1 ;; esac
}

snapshot
if [ "$_running" = 1 ] || [ "$_hooked" = 1 ]; then
    echo "🔴 stopping Pi-Sing"
    "$CLI" stop
else
    echo "🟢 starting Pi-Sing"
    "$CLI" start
fi

echo ""
snapshot
if [ "$_running" = 1 ]; then
    echo "Pi-Sing is ON"
elif [ "$_hooked" = 1 ]; then
    # `stop` removes the rules before it touches the core, so this means the
    # removal failed: say it instead of a reassuring OFF.
    echo "Pi-Sing is OFF but the TPROXY rules are still installed"
    echo "run: su -c '${CLI} iptables off'"
else
    echo "Pi-Sing is OFF"
fi
echo ""
"$CLI" status
