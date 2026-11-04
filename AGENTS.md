# Pi-Sing — agent guide

Magisk / KernelSU / APatch module that runs **only sing-box** as a transparent
proxy (TPROXY, TCP + UDP, no TUN) on a rooted Android phone. Not a generic
sing-box frontend: every rule here exists because of something measured on a real
device (Android 17, kernel 6.12, KernelSU 3.3.1) — see `README.md`.

## The rule behind the rules

> Cái giá phải trả là rẻ nhất, cho mọi công việc có chất lượng tốt nhất.

Pay the cheapest price that still buys the best result, on every job. In this
repo that is a measurement, not a slogan: one `read` per file instead of 34 `cat`
forks (400 ms -> 35 ms per watchdog tick), the tick that already exists instead
of a new process and timer, the `system/bin` symlink the manager already mounts
instead of a wrapper in `/dev`, the user's own DNS `detour` kept instead of a
config rewrite once an A/B showed the rewrite bought nothing. Cheapest is
measured against the result, never instead of it: if the cheap version cannot be
shown to work, it is not cheaper, it is unfinished.

## Non-negotiables

These are not style preferences; each one prevents a concrete failure.

1. **Never proxy the host container's traffic.** The Debian container this agent
   runs in reaches the internet *through the phone*, on `ds-br0` / `ds-v*` /
   `vgate0`. `bypass_interfaces` (default `ds-br+ ds-v+ vgate0 dummy0`) and the
   `172.16.0.0/12` entry in `PISING_BYPASS`/`PISING_SKIP` are what keep that path
   alive. Never remove them, never add `ds-*`, `vgate*` or `wlan+` to
   `ap.list.cfg`, and check the container's own exit IP after every rule change:
   `curl -4 -s https://api.ipify.org` must stay the phone's carrier address.
2. **Never reboot the phone to test.** The agent's own session dies with the
   network. Exercise `service.sh` by running it directly.
3. **Arm a revert before touching device rules.** Pattern: `run/keep` absent +
   `sleep N; [ -f run/keep ] || pi-sing stop` in the background, then apply, then
   verify, then `touch run/keep`. If anything looks wrong, `pi-sing stop` through
   the bridge — the bridge is a unix socket, it works without a network.
4. **Never commit credentials.** `module/payload/config/config.json` is a **template**
   with dummy keys and `203.0.113.10`. The real config lives only at
   `/data/adb/pi-sing/config/config.json` on the phone and is never copied into the repo.
   `customize.sh` keeps an existing config on upgrade, so the template is only
   used on a fresh install.
5. **One command per `su -c`.** `su -c 'a; b'` over android-bridge runs in the
   shell domain (no `/data/adb` access, iptables `Permission denied`). Push a
   script and run `su -c 'sh /data/local/tmp/x.sh'`.
6. **POSIX sh only.** Every script is run by Android's `/system/bin/sh` (mksh) and
   validated with dash: `sh -n`. No arrays, no `[[ ]]`, no `local` assumptions, no
   bashisms.

## Layout

```
module/module.prop            id=pi-sing, version/versionCode bump per release
module/customize.sh           installer; SKIPUNZIP=1; must extract module.prop itself
module/service.sh             boot service: wait for sys.boot_completed + default route
module/action.sh              manager action button -> toggle
module/uninstall.sh           stop, drop rules, delete /data/adb/pi-sing
module/META-INF/.../update-binary   unmodified Magisk module_installer.sh (GPL-3.0)
module/payload/settings.ini   the only knobs; sourced by both scripts
module/payload/bin/pi-sing    CLI: start|stop|restart|status|log|iptables|update-core|watchdog
module/payload/bin/pi.iptables  rules: on|off|renew|v6enforce|status
module/payload/bin/sing-box   NEVER shipped and not committed; update-core installs
                              the core on the phone (tools/fetch-sing-box.sh is for
                              host tests / a manual push only)
module/payload/config/config.json       the config that ships: complete and working,
                              WireGuard keys are 32 zero bytes (no real credentials)
module/payload/config/config.example.json  minimal direct-outbound config
module/payload/lists/package.list.cfg   per-app list (uid or package[:user])
module/payload/lists/ap.list.cfg        interfaces whose ingress is proxied
tools/fetch-sing-box.sh       pinned release + sha256
tools/build.sh                smoke check + dist/Pi-Sing-<version>.zip (module only,
                              the core is never bundled; --full is refused)
tests/smoke-check.sh          sh -n on every script + sing-box check on both configs
tests/netns-tproxy-test.sh    end-to-end in a throw-away netns (27 assertions:
                              TPROXY/DNS/per-app, hotspot ingress captured unless
                              it matches the uplink, PISING_DRY_RUN prints
                              without installing, ipv6=disable sets and restores
                              sysctls, an interface created after `on` inherits the
                              `default` template, `v6enforce` undoes what netd
                              turns back on)
tests/cli-test.sh             host, stub core: dashboard resolution (relative /
                              object / absolute), core_log_level, 🟢/🔴 description,
                              log split/rotation, watchdog vs a user stop, a decoy
                              process that mentions bin_path is not the core,
                              services[].dashboard left alone, a failing name lookup
                              flagging run/dns.failed and the 🟠 DNS card while the
                              rules stay (35)
tests/action-test.sh          host: fail-closed state (rules stay, core dies) and
                              the action button's one-press OFF, the 🟠 card, the
                              watchdog not repainting 🟢 over it, a stale verdict not
                              carried into the next start, log.output warned about,
                              a core that dies during the probes taking the rules
                              with it (32)
tests/installer-test.sh       customize.sh on the host: fresh install, system/bin
                              symlinks into the data dir (no wrapper files, nothing in
                              /dev), v1.0.0 migration, run/ui left alone, stale watchdog
                              (SIGTERM ignored), idempotency, volume keys via a fake
                              getevent (wall-clock window, drained queue), thin zip
                              with/without a core (67)
tests/update-core-test.sh     update-core against a fake release API served locally:
                              digest, a compact one-line payload (what GitHub
                              serves), a release with no digest at all, swap +
                              restart, no-op, refusal, rollback, first
                              core on a thin install (no previous binary to back up),
                              update_mirror rewriting only github URLs (38)
```

On the device: module scripts in `/data/adb/modules/pi-sing`, everything that can
change in `/data/adb/pi-sing`:

```
module/system/bin/      pi-sing, pi.iptables: symlinks -> /data/adb/pi-sing/bin/*
settings.ini            only real file at the top (defines bin_dir, config_dir,
                        list_dir, run_dir, log_dir)
bin/                    pi-sing, pi.iptables, sing-box, sing-box.LICENSE
config/                 config.json, config.example.json
lists/                  package.list.cfg, ap.list.cfg
run/                    pid, stopped (stop intent), generated lists, cache (-D run/)
run/log/                module.log, sing-box.log (+.1 each)
```

The CLI is exposed through the module's `system/bin`, which the manager's mount
hook (Magisk magic mount, or the Hybrid Mount metamodule on this phone) overlays
onto `/system/bin` — the same shape as `/data/adb/modules/droidspaces` ->
`/system/bin/droidspaces` (a symlink into `/data`). Do not reintroduce wrapper
files in the data dir or in `/dev`: that was v1.5.0 and older, and the installer
now removes them. The symlink target is the data dir on purpose — the scripts are
replaced there by `update-core` and reinstalls without waiting for the mount.
Nothing in the module may depend on `pi-sing` being on PATH: `service.sh`,
`action.sh`, `customize.sh` and the installer call `$DATA/bin/pi-sing`.

The flat v1.0.0 layout is migrated by `customize.sh`, which appends the `*_dir`,
`log_dir` and `core_log_level` lines to an old `settings.ini` (existing values
untouched). Without the path block `pi-sing`/`pi.iptables` refuse to run —
deriving `bin_dir` on "/" would be a silent misconfiguration.

**The installer always prints the volume-key prompt** (UP = check GitHub for a
newer core, DOWN = keep the core already on the phone, 15 s no key = keep). Never
make it conditional on anything: it was once conditional and users reported the
missing prompt as a bug. There is one zip and it carries no core, so on a first
flash "keep" means "still no core" (the installer prints the update-core command).
`PISING_INSTALL_CORE=1|0` answers without a key and `PISING_KEY_WAIT=<s>`
shortens the window (tests).

The wait is a **wall-clock deadline**, and the input queue is drained before the
prompt is printed. `getevent -lqc 1` returns on the first event of *any* kind and
this phone streams touch/nav events, so counting reads made the advertised 15 s
last ~2.4 s (measured: 5 reads = 787 ms); a volume key pressed to scroll the
manager log would answer a question the user has not read yet. Same shape as
`box_for_magisk` (`date +%s` deadline, drain in front of every prompt).

**A relative `services[].dashboard` is resolved next to config.json** (never
against `-D run/`), an absolute path is used as is. `sync_dashboard` rewrites only
that value at start; the old `run/ui` copy is moved to `config/ui` by the
installer. Do not hardcode a ui/ directory anywhere.

## Rule contract (do not reorder without re-measuring)

`PISING_EXT` in mangle `PREROUTING`: bypass interfaces → DNS (53 tcp/udp) TPROXY →
`PISING_BYPASS` (**ACCEPT**) → `-i lo` TPROXY → `ap.list.cfg` interfaces TPROXY.

`PISING_LOCAL` in mangle `OUTPUT`: core gid RETURN → own_mark RETURN →
`ignore_interfaces` RETURN → `PISING_SKIP` (**RETURN**) → DNS MARK → per-app →
blanket MARK.

Why it must stay this way (each measured — see README):

- `ACCEPT` in PREROUTING bypass, `RETURN` in OUTPUT bypass. Anything else either
  loops the core's own answers (25k `inbound packet connection` lines for one
  request) or skips the vendor mangle chains behind us (`qcom_NWMGR`,
  `oplus_tos_mapping`, `connmark_*`).
- DNS rules before every bypass, or a private resolver escapes the hijack.
- The core bypass must be by **gid** (`net_admin`, 3005) — `outbound.routing_mark`
  alone does not stop the DNS transport from being captured.
- `ipv6=block` returns for `fe80::/10` **before** rejecting IPv6 DNS. Measured: netd
  held `fe80::1%wlan0` as its resolver while `1.1.1.1`/`1.0.0.1` were marked
  `BROKEN` (18/24 and 24/24 timeouts, score 0, sample validity 1800 s), so
  rejecting IPv6 DNS left it with no resolver: every uncached name failed with
  `ping: unknown host` (8/8 fresh names with rules up, 8/8 resolving with them
  down), while the hijacked IPv4 DNS answered a root shell in 25-270 ms. Letting
  link-local DNS out fixed it (5/8 immediately, healing after). Cost: names go to
  the LAN router (a DNS leak). Global IPv6 DNS is still rejected.
- `ipv6=disable` is the leak-free version of the above and needs no reject: it
  writes `disable_ipv6=1` (+ `accept_ra=0`, `autoconf=0`) to every
  `/proc/sys/net/ipv6/conf/*` except `lo`, so netd has no IPv6 resolver at all.
  The previous values are saved in `run/v6.stack.saved` and restored by
  `off`/`stop` — a module that leaves the stack off after a stop would break the
  phone on its own. `tests/netns-tproxy-test.sh` asserts both directions.
- `-D` needs the full match spec (`-m socket --transparent`), or `PISING_DIVERT`
  survives `stop`.
- **The hotspot interface is `wlan2` on this OPPO** (measured: `10.155.19.27/24`
  while the uplink was `rmnet_data2`), so `ap.list.cfg` ships `wlan1`/`wlan2`
  next to `ap+`/`swlan+`/`rndis+`/`ncm+`/`eth+`. `read_ap_list` drops any entry
  that matches the interface carrying the default route: capturing the uplink's
  ingress proxies traffic that merely passes through (and the dev container's own
  path). `PISING_UPLINK_IF=<iface>` overrides the detection for tests or a ROM
  where `ip route get` answers from the wrong table.

## Testing

Host (this container; kernel has xt_TPROXY, `ip netns` works):

```
SINGBOX_BIN=/root/tmp/sbref/sing-box-1.14.4-linux-arm64/sing-box tests/smoke-check.sh
SINGBOX_BIN=... tests/netns-tproxy-test.sh          # 27/27 expected
tests/update-core-test.sh                           # 44/44 expected, no device
tests/installer-test.sh                             # 67/67 expected, no device
tests/cli-test.sh                                   # 35/35 expected, no device
tests/action-test.sh                                # 32/32 expected, no device
tools/build.sh                                      # smoke + the module zip (no core)
```

Device (root through android-bridge):

```
S=/run/android-bridge/bridge.sock            # may also appear as /run/android-bridge/android-bridge/bridge.sock
android-bridge -s $S -T su -c 'sh /data/local/tmp/x.sh'
android-bridge -s $S push ./local-file /data/local/tmp/local-file   # then su cp into /data/adb
```

### Touching rules on the live phone: one revert, one process

The phone is the agent's own uplink and the container reaches the internet
through it, so every rules experiment needs a way back that does not depend on
the agent staying connected.

```
rm -f /data/adb/pi-sing/run/keep
nohup setsid sh -c "sleep 150; [ -f /data/adb/pi-sing/run/keep ] || /data/adb/pi-sing/bin/pi-sing stop" &
echo $! > /data/local/tmp/revert.pid        # always remember which one
... apply, verify ...
touch /data/adb/pi-sing/run/keep
```

- **Exactly one armed revert at a time.** Measured failure: a second script's
  `rm -f run/keep` re-armed the *first* killer, it woke up mid-test, ran
  `pi-sing stop`, and the module looked like it had crashed on its own (card went
  🔴, rules 0, core stopped). Kill the previous killer by pid before arming a new
  one, or reuse the same script.
- **A stale `run/keep` silently disables the next revert** (the killer finds it
  and does nothing). `rm -f run/keep` at the start of every rules run.
- Verify from *both* sides: `pi-sing status` on the phone **and**
  `curl -4 https://api.ipify.org` in the container. If the container's IP stops
  matching the phone's, stop the module before investigating anything else.
- `PISING_DRY_RUN=1 pi.iptables on` prints every command it would run and leaves
  the rule set byte-identical (measured: mangle table md5 unchanged, 81 lines) —
  use it before installing rules on an unfamiliar ROM.
- Never `pkill -f <path>` and never trust `pgrep -f` alone: the Droidspaces
  container shares the phone's PID namespace, so the pattern matches the shell
  running the command (measured: exit 137). Kill by the pid in `run/pi-sing.pid`
  and check `is_core_pid` (it reads `/proc/<pid>/cmdline`).

A useful device check set (all must hold):

| check | expectation |
| --- | --- |
| `curl -s https://1.1.1.1/cdn-cgi/trace` | proxy exit IP, not the carrier IP |
| `curl -o /dev/null -w '%{remote_ip}' https://www.wikipedia.org` | `198.18.x.x` (fakeip) = DNS goes through sing-box |
| `curl -sL https://edns.ip-api.com/json` | resolver is the tunnel-side one, not the ISP |
| `curl -6 https://ipv6.icanhazip.com` | fails |
| container `curl https://api.ipify.org` | carrier IP (bypassed) |

## Android traps already paid for

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
- **`pidof sing-box` matches every sing-box process**, so `find_pid` cannot tell
  two cores apart; `do_stop` trusts `run/pi-sing.pid` first for that reason. A
  second core (or a test harness) must use its own `bin_name`, otherwise a stop
  can kill the live one (measured while testing `update-core`).
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
- **The release JSON is one line of compact JSON** (285 079 bytes measured) and
  toybox `sed`/`awk` give up on a line that long, so a layout-based parse finds
  nothing. `update-core` now joins the payload into one line and splits it at
  every `{` first, and a missing `digest` warns instead of refusing (sing-box's
  tarballs have no digest; only its APK assets do).
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
- **The watchdog is started by `service.sh` only, so it re-execs itself when the
  script changes.** Measured 2026-11-04: a new `pi-sing` was pushed to
  `/data/adb/pi-sing/bin` and `pi-sing restart` did not touch the loop that had
  been running since boot, so the new per-tick work never happened until the loop
  was restarted by hand. `do_watchdog` compares `cksum "$0"` once per interval
  and `exec`s itself on a change (same pid). Killing a stale loop by hand needs
  the pid plus `/proc/<pid>/cmdline`, never `pgrep -f "pi-sing watchdog"` (toybox
  matches either word and lists `sing-box`).
- **An old `settings.ini` has no `core_log_level`**: resolve the default in a
  variable (`_lvl="${core_log_level:-warn}"`) before using it under `set -u`, or
  awk never runs and the config keeps `info` (measured on the first device
  install).

## Release

1. Bump `version` and `versionCode` in `module/module.prop`.
2. `SINGBOX_BIN=... tools/build.sh` → `dist/Pi-Sing-<version>.zip` + sha256,
   module only. Nothing is pinned to a core release: the zip has none, and
   `update-core` follows GitHub's latest (the digest comes from the same API
   response when the asset has one; sing-box's tarballs do not, so that path
   warns and verifies by tag + `check`). A core in `module/payload/bin/` (from `tools/fetch-sing-box.sh`,
   needed by the host tests) is not copied into the zip.
3. Check the zip before publishing: `python3 -c "import zipfile;z=zipfile.ZipFile('<zip>');print(len(z.namelist()))"`
   must print **15** and the largest entry must be `payload/bin/pi-sing` (~32 KiB).
   A `config/ui/` directory inside `module/payload/config/` once shipped 6.7 MB of
   dashboard assets that way (v1.7.0); the dashboard belongs to sing-box and is
   downloaded at runtime, never committed.
4. `SINGBOX_BIN=... tests/netns-tproxy-test.sh` and the device check set above.
   `tools/build.sh` already runs smoke + cli-test + action-test + installer-test.
5. Commit subject: `pi-sing: <what changed>`; body explains the measurement, not
   the intention.
