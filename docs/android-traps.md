# Android traps already paid for

Each bullet cost a measurement on the phone; none is a theory. Keep the numbers
when you edit them.

- `type: local` DNS servers do not work (`read udp [::1]:53: connection refused`).
- Remote rule-sets are initialized **before** the endpoint is up: give
  `http_clients` a `detour` + `domain_resolver`, otherwise
  `lookup github.com: WireGuard is not ready yet` is fatal.
- A DNS `detour` may be a selector, never a plain `direct` outbound
  (`detour to an empty direct outbound makes no sense`).
- `check` is weaker than `run`: the DNS-detour error above only appears at start.
- KernelSU's installer does not extract `module.prop` when `SKIPUNZIP=1`.
- `pidof`/`pgrep`/`ss`/`curl`/`awk`/`sed`/`sort` exist on the target ROM; busybox
  is at `/data/adb/ksu/bin/busybox` (found by explicit path, not via PATH).
- **toybox `pgrep -f "a b"` matches `a` OR `b`** (measured: the pattern
  `"pi-sing watchdog"` also listed `sing-box`). Match a full command line by
  reading `/proc/<pid>/cmdline` instead; never `pkill` from a split pattern.
- **The watchdog loop survives SIGTERM** (measured: `kill -15` returned 0 and the
  `sh` stayed in its `sleep`, its `sleep` child died). Escalate to SIGKILL.
- **`pidof sing-box` matches every sing-box process, and `run/pi-sing.pid`
  outlives a reboot**, so neither is the core by itself: a pid from either
  source has to pass `is_core_pid` (its executable, or the script it was launched
  as, is this `bin_path`). Measured 2026-11-19 10:45:35 in `module.log`: the
  first start after a boot logged `already running (pid 8143)` for a pid written
  before that boot — no core and no rule for 85 s — and the `stop` that followed
  logged `sing-box stopped (pid 8143)`, a SIGTERM to a process that was not ours.
  Without that check a second core (or a test harness) with the same `bin_name`
  could be killed by a `stop` (measured while testing `update-core`); measured
  2026-11-21 with the live core as pid 26063, an instance in another data dir
  with the same `bin_name` reads `process : stopped`.
- KernelSU 3.3.1 stages a module update in `/data/adb/modules_update` and applies
  `service.sh`/`action.sh` only on the next boot. Between an in-app upgrade and a
  reboot the previous boot script still runs; it calls `$DATA/bin/pi-sing`, which
  the installer has already replaced, so nothing has to be created in `/dev` for
  that window (v1.5.0 wrote `/dev/pi-sing` from `service.sh` for it). The
  `system/bin` symlinks appear at the next boot with the mount.
- **`services[].dashboard` is sing-box's.** The module does not resolve, rewrite
  or move it, `status` does not print it, and the installer touches neither the
  value nor `run/ui` (the old code rewrote a relative value to `<config_dir>/ui`
  and moved `run/ui` there). A relative value resolves against the core's own `-D`
  (`run/`). Tested in `tests/cli-test.sh` and `tests/installer-test.sh`.
- **The watchdog restarts a crashed core but must not undo a user stop.** `stop`
  writes `run/stopped` before killing the core, `start` removes it, and the
  watchdog loop skips restart *and* rule renewal while it exists. Without the flag,
  the action button's OFF came back at the next 30 s tick (measured).
- **The rules must not outlive the core.** A killed core with the rules still
  installed captures every packet to a dead port: the phone is offline until
  somebody runs `stop`, and on a config the core cannot survive that looks like
  "the action button is broken" (measured: `kill -9` the core with rules in place,
  `curl 1.1.1.1` on the phone rc 35 with the card still 🟠). `do_start` and the
  watchdog call `drop_rules_if_dead` after any failed attempt, and the card is
  derived from the real state (`update_state`), never from what the caller hoped.
  Same rule as `box_for_magisk` (`box_bin_alive` / `restart_box`: no pid →
  `iptables disable`). A *live* core with a dead tunnel still keeps the rules (no
  leak); the action button's single press is the way out.
- **"ON" means the TPROXY rules are installed, not just "a core is running".** A
  start whose self-test fails keeps the rules (fail closed, no leak) and the core
  can exit a moment later, so `process : stopped` + `iptables : hooked` is a
  normal state. Deciding the toggle on the process alone made the next press run
  `start` again: the rules were never removed, the phone had no internet, and the
  only way back was uninstalling the module (whose `uninstall.sh` runs `stop`) and
  rebooting (measured on a user report, `2026-11-04`). `run/selftest.failed` keeps
  the card 🟠 so the watchdog cannot paint it 🟢 while the tunnel is unproven.
- **`find_pid` must fall back to `pgrep -f "$bin_path"`** when `pidof` finds
  nothing: pidof matches the kernel comm, which is not `bin_name` for a wrapper.
  The pgrep hit alone is not enough — `is_core_pid` also requires bin_path as an
  argv token of that pid plus `/proc/<pid>/exe` (or argv[0]/argv[1]). Measured:
  the Droidspaces container **shares the phone's PID namespace**, so a shell whose
  command line mentioned `/data/adb/pi-sing/bin/sing-box` was taken for the core
  and `stop` SIGKILLed it (the agent's own shell, exit 137). Never `pkill -f` a
  path from a bridge command either: the pattern matches the command you are
  running.
- **netd owns the packet mark by the time the filter table runs.** mangle `INPUT`
  on this ROM ends in `routectrl_mangle_INPUT`, one `-i <iface> -j MARK
  --set-xmark <netid>/0x7fefffff` per interface netd manages (read 2026-11-21:
  `wlan0` → `0x300cd`), and that mask covers the module's fwmark bit. A rule
  that has to see the TPROXY mark must sit in mangle and ahead of that chain:
  `PISING_INPUT` is the first rule of mangle `INPUT` for that reason
  (`docs/rules.md`, "Nothing but TPROXY reaches the tproxy port").
- **A DNS server's own transport ignores `route.final`.** In 1.12+ a DNS server
  dials "just like an outbound", which the docs call *equivalent to an empty
  direct outbound*: without `detour` the DoH/DoT query leaves the phone directly
  even when `final` is a proxy. Measured on the host with 1.14.4: a server with
  `"detour": "blocked"` fails (`operation not permitted`), the same server
  without `detour` works while `route.final` is a `block` outbound. On the phone a
  leak test showed the carrier-side resolvers until `remote_dns` got
  `"detour": "Soul_🌐"`; the debug log then printed
  `endpoint/wireguard[Proton-US_🔒]: outbound connection to 8.8.8.8:443`.
  `route.default_domain_resolver` is **not** this knob: it only sets the resolver
  outbounds use for the domains *they* dial (docs Dial Fields).
- **A DNS `detour` is paid by every name that resolver answers, and the dial-time
  destination lookup uses `route.default_domain_resolver` — so a "mostly direct"
  config must not point it at a tunnel-side server.** Measured 2026-11-05 on the
  user's own config (`remote_dns` = DoH 8.8.8.8 with `"detour": "Soul_🌐"`,
  `default_domain_resolver` = `remote_dns`, everything else direct): `github.com`
  tls 0.43-0.97 s / total 1.6-3.3 s, `api.github.com` tls 0.43-0.50 s, while the
  same server family by IP literal cost tls 0.11-0.20 s — the name of a *direct*
  connection was being resolved through the tunnel. Adding
  `{"type": "https", "tag": "direct_dns", "server": "1.1.1.1"}` (no `detour`) and
  pointing `default_domain_resolver` at it: tls 0.11-0.14 s, total 0.28-0.36 s,
  exit IP unchanged (direct), a package that *is* proxied still left through the
  endpoint (`api.ipify.org` → `185.98.169.17`), core clean (`FATAL 0`).
  - `"detour": "Direct_🦈"` on that server is fatal at `run` only:
    `FATAL start service: start dns-transport: start dns/https[direct_dns]: detour
    to an empty direct outbound makes no sense` — a selector whose only member is
    `direct` is empty, same rule as the bullet above but one level up. `check`
    passes it; the module then fail-closes (rules dropped) so the phone stays
    online and the card goes 🟠, which is how it was noticed.
  - `domain_resolver` on a non-`direct` outbound/endpoint covers only its **server
    address** (docs Dial Fields), never the destinations its tunnel carries, so it
    cannot keep proxied names in-tunnel; `route.default_domain_resolver` decides
    those. The trade-off after the switch is that names for proxied destinations
    are answered by 1.1.1.1 over DoH directly — encrypted, just not through the
    tunnel. The shipped template has no `detour` on `remote_dns`, so it is not
    affected.
  - **`dns.rules[].server` and `dns.final` are the same tax on a second path.**
    After the default resolver was fixed, two rules (`geosite-telegram`,
    `...googleapis.com`) and `dns.final` still pointed at the tunnel-side DoH, so
    those names paid a tunnel round trip while their traffic went direct. Moving
    all three to `direct_dns`: `www.googleapis.com` tls 0.76 s -> 0.185 s,
    `telegram.org` answered with a real IP (149.154.167.99) instead of a fakeip,
    `github.com` total 1.6-3.3 s -> 0.27-0.58 s, exit IP still direct
    (115.77.59.104) and a `package_name` rule that is proxied still left through
    the endpoint (uid 10492 -> 185.98.169.17). `remote_dns` ends up referenced by
    nothing (`grep '"server": "remote_dns"'` = 0) and can stay defined for when a
    name really should be resolved inside the tunnel. Never move the endpoint into
    the `all` list of the direct selector on this phone — that separation is the
    user's, by design.
- **The release JSON is one line of compact JSON** (285 079 bytes measured) and
  toybox `sed`/`awk` give up on a line that long, so a layout-based parse finds
  nothing. `update-core` joins the payload into one line and splits it at every
  `{` first. **That split cuts an asset object in two**: GitHub nests an
  `uploader` object between `name` and `digest`, so the quoted name is on one
  line and the digest on the next, next to `browser_download_url`. Looking for
  the digest on the name's line found nothing, ever: until 2026-11-21 every
  update logged "publishes no sha256 digest" and no sha256 was verified (against
  the live payload a tarball with another sha256 installed with rc 0). The note
  that used to stand here, "sing-box's tarballs have no digest", was that bug —
  v1.14.4 has 168 assets and 168 digests. The digest is now taken from the line
  that carries the name or the download URL (script == API for android-arm,
  -arm64, -amd64 and -386), and an asset that really has none still installs,
  with the warning. The test fixture has GitHub's shape now; the flat one it had
  is what hid this.
- **`sing-box check` does not open `log.output`, `run` does.** Measured with a
  box_for_magisk config (2026-11-04): `check` exits 0, then `run` dies with
  `start logger: open /data/adb/box/run/sing-box.log: no such file or directory`
  one second after the rules went in. `do_start` logs a warning when the key is
  present, and `drop_rules_if_dead` removes the rules the dead core left behind,
  so the phone stays online. Do not "fix" the user's config: report it.
- **`--disable-color` is detected, not assumed** (`run --help | grep`), and the log
  level is written into config.json from `core_log_level` (default `warn`). One
  INFO line per connection was 4 633 B/min on the device; at warn an idle core
  writes nothing.
- **netd turns IPv6 back on, so `ipv6=disable` cannot be a one-shot sysctl.**
  Measured 2026-11-04: the boot start logged `IPv6 stack off on 29 interface(s)`,
  then WiFi connected, netd brought `wlan0` up with `disable_ipv6=0`, droidspaces
  created `ds-br0` (also 0), netd's resolver list held `fe80::1%wlan0` and the
  names left for the LAN router — the leak the mode exists to prevent. Two things
  fix it: the `default` template is written too (an interface created later
  inherits it), and the watchdog calls `pi.iptables v6enforce` every tick, which
  re-applies only what drifted (a few file reads, one log line when it acts).
  It runs forever, so it has to be cheap: one `read` per file instead of `cat`
  (measured on the device: 400 ms -> 35 ms per tick, 128 ms when it has to fix
  something), and never `read ... || continue` — a `/proc/sys` value has no
  trailing newline, so dash returns 1 there while still setting the variable
  (measured: every interface read "1" and nothing was fixed).
  **The cadence matters as much as the cost.** `v6enforce` once per tick left a
  window as wide as `watchdog_interval`: measured 2026-11-05, switching wifi ->
  4G and running a leak test inside those 30 s answered from the carrier's
  resolvers (`Viettel 171.225.222.19/.20`) while the card stayed 🟢, and only the
  next tick closed it — so a fast switch always leaked. The loop now wakes on a
  2 s slice and calls `v6_drift` first; a drifted uplink is fixed in ≤2 s
  (measured 0.1 s / 1.1 s / 1.6 s over three runs).
  **Count the children when you measure the loop.** The first `v6_drift` was
  `ip route get | awk` for the uplink alone, and the tick ran a full
  `pi.iptables v6enforce` on top. Its "70 ms of CPU per minute" was the shell's
  own time; measured 2026-11-22 with `cutime`+`cstime` of the loop's pid it was
  1.12 s per minute (75 ms by itself, the rest forks: `ip route get`+`awk`
  11 ms, `sleep` 8.7 ms, per call). `v6_drift` now reads every interface's
  `disable_ipv6` with the shell's own `read` (34 files: 1 ms, no fork) and
  starts `v6enforce` only when one is 0 — the same condition v6enforce acts on —
  so the tick no longer runs it. Measured on the device after the change: 0.66 /
  0.72 / 0.76 s per minute over three 60 s windows with no drift (what is left is
  mostly `sleep`, `cksum`, `running_pid` and the tick's `ip route get`), and an
  interface that is not the uplink is fixed in 0.9 / 1.2 / 1.1 s instead of at
  the next tick (`dummy0` set to 0 by hand; before: `ds-br0` in 7 s). A value
  that does not stay written is retried on the tick, not every slice, so it
  cannot turn into a pi.iptables run and a log line every 2 s.
  `all/disable_ipv6` must still stay untouched: writing it cascades to `lo` and
  kills `::1` (measured).
- **A resolver that dies while the tunnel still works is a leak, not a tunnel
  failure.** The 2026-11-04 leak test ran at the exact second WiFi became the
  default network: `sing-box.log` shows `dns: lookup failed ... SERVFAIL` for
  every name while `https://1.1.1.1/cdn-cgi/trace` still answered, and the test
  then reported the ISP's resolvers because the app resolved through netd (over
  `fe80::1%wlan0`, which IPv6-off no longer leaves reachable). So the selftest and
  the watchdog probe a **name** (`www.gstatic.com/generate_204`), not only an IP
  literal: literal ok + name failing writes `run/dns.failed`, the card goes 🟠
  `DNS failing - names leak` and the rules stay (closing the tunnel would only
  move the leak).
  The `detour` of a DoH server is **not** the cause: A/B measured the same day
  with `remote_dns` = DoH `8.8.8.8` both with `detour: Soul_🌐` (through the
  WireGuard endpoint) and without it — the leak test answered
  `Google 172.253.0.x` and `Google 74.114.31.x` respectively, i.e. no ISP
  resolver either way, and `0` conntrack entries existed for the ISP resolvers the
  failing test had named. Keep the user's `detour`; only the detection above is
  this module's business.
- **The watchdog re-execs itself when the script changes, and `start` has to
  bring it back.** Measured 2026-11-04: a new `pi-sing` was pushed to
  `/data/adb/pi-sing/bin` and `pi-sing restart` did not touch the loop that had
  been running since boot, so the new per-tick work never happened until the loop
  was restarted by hand. `do_watchdog` compares `cksum "$0"` once per interval
  and `exec`s itself on a change (same pid). Killing a stale loop by hand needs
  the pid plus `/proc/<pid>/cmdline`, never `pgrep -f "pi-sing watchdog"` (toybox
  matches either word and lists `sing-box`).
  Only `service.sh` used to start the loop, so a `restart`, the action button or
  `update-core` left the phone without it until the next boot — measured
  2026-11-05: the loop was gone from 00:05 (nothing logged after 23:37, no such
  process), `wlan0/disable_ipv6` was back to 0 at 00:12, and the wifi -> 4G leak
  test in between answered from the carrier's resolvers. `do_start` now calls
  `ensure_watchdog`, which trusts `run/watchdog.pid` only together with
  `/proc/<pid>/cmdline` (a recycled pid must not hide a dead loop) and spawns
  `nohup setsid sh $0 watchdog` when `watchdog=1`. Through `sh`, not by executing
  the file: its shebang is `/system/bin/sh`, which does not exist on a host test
  copy — that copy died before its first line, silently, and the new cli-test case
  caught it. Measured on the device: kill the loop, `pi-sing start` logs
  `watchdog is not running, starting it`, the new loop writes `run/watchdog.pid`,
  a second `start` keeps exactly one loop, and its probe fixed a forced
  `disable_ipv6=0` in 0.4 s.
- **One watchdog loop, whoever starts it.** `service.sh` runs `start` (whose
  `ensure_watchdog` spawns a loop) and then `watchdog`, so every boot ended with
  two. Measured on the device 2026-11-21: pids 3651 and 10920 both
  `pi-sing watchdog` since the boot of 11-19, 70 of 95 renews logged twice in the
  same second, three rule builds that ran into each other (`iface ap+ not
  available yet` is what a chain flushed under a builder looks like), and a
  mangle table with every rule twice (`PISING_EXT` 74 rules, 23 distinct).
  `do_watchdog` leaves when `run/watchdog.pid` names another live loop — at
  entry, or at its first wake-up when two started in the same instant and both
  found no loop. Checked through the real `service.sh` in `tests/cli-test.sh`,
  and on the device under mksh.
- **An old `settings.ini` has no `core_log_level`**: resolve the default in a
  variable (`_lvl="${core_log_level:-warn}"`) before using it under `set -u`, or
  awk never runs and the config keeps `info` (measured on the first device
  install).
