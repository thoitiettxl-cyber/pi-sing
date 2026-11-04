# Pi-Sing

A Magisk / KernelSU / APatch module that runs **only sing-box** as a transparent
proxy (TPROXY, TCP + UDP, no TUN) and is configured to leak neither IPv4, IPv6
nor DNS.

References used to learn the structure (not copied):

- [`CHIZI-0618/AndroidTProxyShell`](https://github.com/CHIZI-0618/AndroidTProxyShell) — rule ordering: DNS hijack before every bypass, `ACCEPT` bypass in `PREROUTING`, `DIVERT` for established sockets, owner-based bypass of the core.
- [`taamarin/box_for_magisk`](https://github.com/taamarin/box_for_magisk) — module layout: `SKIPUNZIP=1` installer, payload in `/data/adb/<mod>`, config kept outside the module dir, boot service.

sing-box **v1.14.4** (`sing-box-1.14.4-android-arm64.tar.gz`).

## Verified on the phone it was built for

OnePlus CPH2747 (OP611FL1), Android 17 / SDK 37, kernel `6.12.69-Weather0P15`,
KernelSU 3.3.1, busybox 1.36.1.1 at `/data/adb/ksu/bin/busybox`, iptables 1.8.11
(legacy) with `TPROXY`, `owner`, `mark`, `socket`, `addrtype` and `SET` available,
uids in `package.list.cfg` resolved from `/data/system/packages.list`.

Measured with the module running (`su -c pi-sing status` → running, rules
installed, watchdog up):

| check | command | result |
| --- | --- | --- |
| traffic capture | `su -c pi-sing log core 200` while an app connects | `inbound/tproxy[tproxy-in]: inbound connection …` for the request; the outbound row then shows the config's chosen outbound (this config sends most rules through a `direct` tag, so the exit address is the carrier's) |
| DNS through the tunnel | `curl -o /dev/null -w '%{remote_ip}' https://www.wikipedia.org` | `198.18.0.32` — a sing-box **fakeip**, so the name was resolved by sing-box, not by Android |
| resolver as the outside world sees it | `curl -sL https://edns.ip-api.com/json` | `Singapore - Google LLC` (`172.253.211.85`), i.e. the resolver named in config.json, not the ISP resolver |
| IPv6 leak | `curl -6 https://ipv6.icanhazip.com` | fails (`rc=6`) and `PISING_V6BLOCK` rejects it; the phone's own `2402:800:…` address never reaches the network |
| QUIC | `iptables -t filter -S PISING_GUARD` | `udp 443`/`udp 80` rejected, so apps fall back to TCP through the proxy |
| container path | `curl https://api.ipify.org` from the Droidspaces Debian container | HTTP 200, the carrier address — the `ds-*`/`vgate0` bypass kept the container online through every restart |

Host-side tests, run on the same kernel:

```
tests/smoke-check.sh                  every script parses (dash), both configs pass `sing-box check` 1.14.4
tests/netns-tproxy-test.sh            14/14 — TCP, UDP/53 hijack, per-app blacklist + whitelist,
                                      core-gid bypass (no capture loop), clean teardown
tests/cli-test.sh                     30/30 — services[].dashboard is left untouched,
                                      core_log_level, 🟢/🔴 description, log split, log rotation,
                                      watchdog leaves a user-stopped core stopped, a process
                                      that only mentions the core path is not the core
tests/action-test.sh                  32/32 — fail-closed state (rules stay, core dies), the
                                      action button's one-press OFF, the 🟠 card, the watchdog
                                      not repainting 🟢, a stale verdict not carried into the
                                      next start, log.output warned about, a core that dies
                                      during the probes taking the rules with it
tests/installer-test.sh               67/67 — fresh install, system/bin symlinks into the
                                      data dir, no entry point in $DATA, migration from the
                                      v1.0.0 flat layout, run/ui left alone, idempotent re-run,
                                      stale watchdog killed, volume-key prompt (+) / (-) on a
                                      wall-clock window, thin zip with no core, failed download,
                                      old settings.ini rejected
tests/update-core-test.sh             44/44 — update-core against a fake release API: digest
                                      verified, swap + restart, "already latest" no-op,
                                      bad digest / failing `check` / dead core refused,
                                      previous binary restored and restarted, first core
                                      on a thin install (no previous binary), update_mirror
                                      rewriting only github URLs
```

Not verified: the `ipv6=proxy` mode (this tunnel carries IPv4 only — measured),
hotspot/tether capture (`ap.list.cfg`), and an actual key press during the
manager's flash UI — `getevent`/`timeout` exist on the ROM and the installer test
drives both keys with a fake `getevent`, but the volume keys were not pressed in
the KernelSU installer itself. Also not verified: the first boot of the service
after a real reboot (the service was exercised by running `service.sh` directly,
as this agent's shell runs through the phone).

## Layout

```
module/                     -> inside the zip
  module.prop               id=pi-sing, name=Pi-Sing
  customize.sh              installer (SKIPUNZIP=1)
  service.sh                late_start service: wait for boot + default route, start, watchdog
  action.sh                 manager action button: toggle on/off
  uninstall.sh              stop, remove rules, delete /data/adb/pi-sing
  META-INF/.../update-binary   upstream Magisk module_installer.sh (GPL-3.0)
  payload/
    settings.ini            every tunable (sourced, POSIX sh)
    bin/  pi-sing           CLI: start|stop|restart|status|log|iptables|watchdog
          pi.iptables       TPROXY rules: on|off|renew|status
          sing-box          NOT shipped; update-core installs it on the phone
    config/  config.json    sing-box config (see "the shipped config" below)
             config.example.json   minimal config: tproxy inbound + direct outbound
    lists/   package.list.cfg    per-app list (blacklist/whitelist)
             ap.list.cfg         interfaces whose incoming traffic is proxied
tests/  netns-tproxy-test.sh, smoke-check.sh, installer-test.sh
tools/  build.sh            -> dist/Pi-Sing-<version>.zip (module only, no core)
```

## Build

One artifact, **no sing-box binary in it** (~29 KiB measured). The core is 79 MiB
of GPL-3.0 software from another project, and `update-core` follows the latest
release anyway, so bundling it only made a second zip and a rebuild per core bump.
The module gets a core on the phone instead:

| how | command |
| --- | --- |
| at flash time | the installer always asks; `(+)` runs `update-core`, `(-)` keeps what is there |
| later, over the air | `su -c pi-sing update-core` (sha256 from the release API, `check` against the live config, rollback if the new core does not stay up) |
| by hand | put a binary at `/data/adb/pi-sing/bin/sing-box` (0755) — a downloaded `sing-box-*-android-arm64` |

```
tools/build.sh                          # -> dist/Pi-Sing-<version>.zip + sha256
tools/build.sh --thin                   # accepted, same file (old commands keep working)
tools/build.sh --full                   # refused: the core is never bundled
```

Every rules command honours `PISING_DRY_RUN=1`: it prints `[dry-run] iptables …`
instead of running it, so a new ROM can be inspected without cutting the network.
`tools/build.sh` runs `tests/smoke-check.sh` first (every script parses, both
configs pass `check`, every payload file is present) and then the CLI, action and
installer tests. It never copies `module/payload/bin/sing-box` into the zip, even
when a binary is lying there for the netns test.

`tools/fetch-sing-box.sh` pins `sing-box 1.14.4`, verifies the tarball sha256 and
puts the binary in `module/payload/bin/` — for the host tests
(`SINGBOX_BIN=... tests/netns-tproxy-test.sh`) or for pushing a core by hand. That
path is gitignored.

```
tools/fetch-sing-box.sh                 # arm64 default, --arch arm|arm64|x86_64|x86
SINGBOX_BIN=/path/to/linux/sing-box tests/netns-tproxy-test.sh
```

On the device:

```
/data/adb/modules/pi-sing/      module.prop, service.sh, action.sh, uninstall.sh
  system/bin/pi-sing            symlink -> /data/adb/pi-sing/bin/pi-sing
  system/bin/pi.iptables        symlink -> /data/adb/pi-sing/bin/pi.iptables
/data/adb/pi-sing/              everything that changes, grouped by purpose
  settings.ini                  the only real file at the top: every knob
  bin/                          pi-sing, pi.iptables, sing-box, sing-box.LICENSE
  config/                       config.json, config.example.json
  lists/                        package.list.cfg, ap.list.cfg
  run/                          pid, stop intent, generated lists, sing-box cache.db
  run/log/                      module.log, sing-box.log (+.1 each)
```

`system/bin` is the only place the CLI is exposed. The manager's mount hook
(Magisk magic mount, or Hybrid Mount — the KernelSU metamodule installed on this
phone) overlays the module's `system/bin` onto `/system/bin`, exactly the way
`/data/adb/modules/droidspaces` exposes `/system/bin/droidspaces`. The module
ships **symlinks into the data dir**, not copies: `update-core` and a reinstall
replace the scripts in place, without waiting for a mount that only happens at
boot. Nothing is written to `/dev`, and the data dir holds no wrapper files any
more (v1.5.0 and older did; the installer removes them).

`bin/` and `config/config.example.json` are replaced on upgrade; `settings.ini`,
`config/config.json` and the two files in `lists/` are kept. An install from the
old flat layout is moved into these directories by `customize.sh` (existing
values untouched), and an older `settings.ini` gets the `*_dir`, `log_dir` and
`core_log_level` lines appended — it does not have them, and the scripts refuse to
guess the paths.

**The installer always asks one question**, whatever the zip carries:

```
  Volume keys (15 s):
    (+) UP   = download the latest sing-box core from GitHub
    (-) DOWN = keep the core already on the phone (none yet on a first flash)
    no key   = keep
```

`(+)` runs the same `update-core` path as the CLI: the release comes from GitHub's
latest tag, the archive is checked against GitHub's sha256 digest when it is
published, and the binary must
pass `check` with the live config. A failed download never aborts the flash — the
bundled or installed core stays and the log says why. `PISING_INSTALL_CORE=1|0`
answers without a key (unattended flashes, tests). With no `getevent` or `/dev/input`
in the installer context, the default (keep) is taken after printing the prompt.

The CLI symlinks only appear in `/system/bin` after the next boot (the mount
runs once, at boot; measured with KernelSU 3.3.1, which stages a module update in
`/data/adb/modules_update` and applies its scripts on the next boot). Until then,
and in every script of the module itself, the absolute path is used:
`su -c /data/adb/pi-sing/bin/pi-sing start`. The installer prints both. A watchdog
loop from the previous version is killed by the installer (SIGTERM then SIGKILL —
the loop survives SIGTERM on this ROM).

## Usage

```
su -c pi-sing start             # run sing-box, install the rules, self-test
su -c pi-sing stop              # remove the rules, stop sing-box (the watchdog stays down)
su -c pi-sing restart
su -c pi-sing status            # process, rules, log paths
su -c pi-sing log 80            # module.log (events)
su -c pi-sing log core 80       # sing-box.log (the core's own output)
su -c pi-sing iptables off|on|renew|status
su -c pi-sing update-core       # install the latest sing-box from GitHub
```

`action.sh` (manager action button) does the same toggle and ends with
`Pi-Sing is ON` / `Pi-Sing is OFF`.

The button counts a rule set that is still installed as **ON**, not just a
running core: a start whose self-test fails keeps the rules (fail closed) and the
core can die afterwards, which used to look "stopped" — so the next press started
the core again, the rules were never removed, and the phone stayed offline until
the module was uninstalled. One press now always reaches a real OFF (rules
removed, core stopped), and `Pi-Sing is OFF` is only printed when both are gone.

`stop` writes `run/stopped`; `start` removes it. The watchdog restarts a **crashed**
core but leaves a **user-stopped** one alone — before this, the action button's
OFF was undone at the next 30 s tick.

## State and logs

- **Module card**: the manager shows `module.prop`'s description under the module.
  Every state change writes one line, the way
  [`android-bridge`](https://github.com/ravindu644/android-bridge) does:
  `🟢 Running (pid …) | sing-box + TPROXY blacklist, 1536`,
  `🔴 Stopped`, `🔴 Stopped - tunnel down`, `🟠 Tunnel down - tap to stop`
  (core up, rules stay: fail closed), `🟠 Core down - tap to stop`,
  `🟠 Running - no rules`, `🔴 Config error`, `🔴 No core`,
  `🔴 Disabled (enabled=0)`, `⚪ Installed - reboot to start`.
  Every state-changing path derives the line from what is true at that moment
  (process alive? rules installed? last self-test unproven?), so the card cannot
  claim a state the phone is not in. The watchdog only rewrites the file when
  the text changes.
- **`run/log/module.log`** — one line per module event, `[cli]` or `[rules]` or
  `[svc]` + level + timestamp. Rotates at 256 KiB to `.1`.
- **`run/log/sing-box.log`** — the core's stdout/stderr only (started with
  `--disable-color`, so no ANSI escapes). One file per run; the previous run is
  `sing-box.log.1`. At the default `core_log_level="warn"` an idle core writes
  nothing, so the file stays at the run header.
- The old `pi-sing.log` (core + module lines mixed), `iptables.log` and
  `service.log` (duplicated stdout) are gone; the installer removes them.

Measured on the device (Android 17, 60 s idle window): the old pair wrote
**4 633 B/min**; the new pair writes **0 B/min** (both files unchanged), and a
start takes ~1 s to the rules instead of ~4 s (`sleep 2` replaced by a pid wait).
The rule set itself is byte-for-byte the same, so packet-processing cost is
unchanged.

## Dashboard (`services[].dashboard`)

`services[].dashboard` is sing-box's, and the module does not touch it: it does
not resolve the path, rewrite the value, move the directory, or print it in
`status`. A relative path is resolved by the core against its own `-D`
(`/data/adb/pi-sing/run`), so `"dashboard": "ui"` ends up in `run/ui` and sing-box
fills it there on start (the official dashboard, ~8 MB, downloaded once). An
absolute path is used as written. Point it wherever you like in `config.json`;
`pi-sing start` will not edit the file for it.

The module used to rewrite a relative value to `<config_dir>/ui` and move an old
`run/ui` there. That was module logic for a core feature, it rewrote a user file
on every start, and it is gone (`box_for_magisk` does the same: its config has the
key and the core does the rest).

## Updating the core

`pi-sing update-core` installs the latest sing-box release; the module does not
have to be rebuilt or reinstalled.

- the release comes from `api.github.com/repos/SagerNet/sing-box/releases/latest`,
  and the asset name follows `ro.product.cpu.abi` (`arm64-v8a` -> `android-arm64`,
  `armeabi-v7a` -> `android-arm`, `x86_64` -> `amd64`, `x86` -> `386`);
- the archive is checked against the `sha256` digest GitHub publishes for that
  asset when the API carries one, so a broken download or a proxy that rewrites
  the body is rejected. sing-box's tarballs currently have **no** `digest` in the
  response (measured on v1.14.4: the APK assets do, `sing-box-1.14.4-android-arm64.tar.gz`
  does not), so a missing digest logs a warning and the install goes ahead on the
  weaker chain: pinned release URL over TLS, exactly one expected binary in the
  tarball, `version` equal to the tag, and `check` passing on the live config;
- the new binary has to answer `version` with the release tag and to pass
  `check -D run/update/check -c config/config.json` — a scratch `-D`, so the live
  `cache.db` is never touched. Only then are `bin/sing-box` and
  `bin/sing-box.LICENSE` replaced;
- the file is swapped **before** the core is stopped, so a watchdog restart in
  between starts the already validated new binary, never the stale one. A running
  core is stopped and started again; if it does not stay up, the previous binary
  is put back and started. With no previous binary (a thin install) there is
  nothing to back up, so the release is installed from scratch;
- same tag as the installed core -> `update: already on the latest core (1.14.4)`,
  nothing is downloaded;
- `update_mirror` (settings.ini) puts an accelerator in front of github.com
  (`https://ghfast.top` style): `https://github.com/…`, `https://api.github.com/…`
  and `https://raw.githubusercontent.com/…` get the prefix, nothing else does. A
  partial download is deleted, never left in `run/update`. The digest still comes
  from the release API, so a truncated download is refused — but the mirror
  answers that API too, so only use one you trust;
- unauthenticated GitHub API access is limited to 60 requests/hour per IP; a 403
  leaves the API body in `run/update/release.json` and the core untouched.

Measured on the device (Android 17, arm64-v8a): against the real API it reported
`already on the latest core (1.14.4)`; the whole path (digest, extraction,
`check`, swap, start) ran in a throw-away data dir against a `file://` release
whose tarball carried the installed 1.14.4 binary — 8/8 checks, live core pid
unchanged.

## settings.ini

| key | default | meaning |
| --- | --- | --- |
| `enabled` | `1` | start at boot from `service.sh` |
| `selftest` | `1` | probe direct + proxied after start, see above |
| `watchdog` / `watchdog_interval` | `1` / `30` | restart a dead core, renew rules when the default route interface changes |
| `tproxy_port` | `1536` | tproxy inbound port; `pi-sing start` rewrites the tproxy inbound's `listen_port` |
| `fwmark` | `0x00200000/0x00200000` | mark set by TPROXY, matched by `ip rule` (outside the `0x0–0x1ffff` range netd uses) |
| `own_mark` / `routing_mark` | `0x00400000` / `4194304` | optional second loop guard (`outbound.routing_mark`) |
| `table` / `pref` | `2027` / `110` | routing table and `ip rule` preference, both free on this phone |
| `ipv6` | `block` | `proxy` = proxy IPv6 too; `block` = reject IPv6 (no leak, link-local DNS still passes); `disable` = switch the IPv6 stack off (`disable_ipv6=1`, restored on stop) so netd has no IPv6 resolver to leak through; `off` = leave it alone (leaks). `true`/`false` are aliases of `proxy`/`block`, `-1`/`none` of `disable` |
| `quic` | `disable` | reject UDP 443/80 so apps fall back to TCP |
| `proxy_mode` | `blacklist` | `blacklist` = proxy everything except listed apps; `whitelist` = only listed apps |
| `bypass_interfaces` | `ds-br+ ds-v+ vgate0 dummy0` | incoming interfaces that are never touched (Droidspaces bridges, VM gateway) |
| `ignore_interfaces` | empty | output interfaces that are never proxied |
| `core_user`/`core_group`/`core_gid` | `root`/`net_admin`/`3005` | the core runs as this uid:gid so its own traffic can be bypassed by gid |
| `core_log_level` | `warn` | level written into `config.json` at start; `config`/empty leaves the file in charge. `warn` keeps one line per connection out of the log |
| `update_mirror` | empty | accelerator prefix for github.com in `update-core` and the installer's download, e.g. `https://ghfast.top` (empty = direct) |
| `log_dir` | `${run_dir}/log` | `module.log` and `sing-box.log` (+`.1`) |

## Rule set (mangle)

`PISING_EXT` — hooked first in `PREROUTING` (empty on this ROM, so `ACCEPT` is safe):

1. `-i <bypass_interfaces>` → `ACCEPT`
2. `tcp/udp --dport 53` → `TPROXY` (DNS hijack, before any bypass so a private resolver is hijacked too)
3. `-j PISING_BYPASS` — private ranges, device addresses → `ACCEPT`
4. `-i lo` tcp/udp → `TPROXY` (locally generated traffic, marked in OUTPUT, rerouted to `lo`)
5. `-i <ap.list.cfg>` tcp/udp → `TPROXY` (tether clients)

`PISING_LOCAL` — hooked first in `OUTPUT` (vendor chains `qcom_NWMGR`,
`oplus_tos_mapping`, `connmark_*` sit behind it, so bypass here uses `RETURN`,
never `ACCEPT`):

1. `-m owner --gid-owner <core_gid>` → `RETURN` (the core itself; without this DNS loops forever)
2. `-m mark --mark <own_mark>` → `RETURN` (second guard)
3. `-o <ignore_interfaces>` → `RETURN`
4. `-j PISING_SKIP` (private ranges → `RETURN`)
5. `tcp/udp --dport 53` → `MARK` (DNS hijacked for every app in both modes)
6. per-app: blacklist → listed uids `RETURN`, then everything marked; whitelist → only listed uids marked
7. `tcp`/`udp` → `MARK`

`PISING_DIVERT` (PREROUTING, `-m socket --transparent`) marks and accepts packets
of an already handled connection. `PISING_GUARD` (filter OUTPUT) rejects direct
connections to the tproxy port and, with `quic=disable`, UDP 443/80.
`PISING_V6BLOCK` (filter OUTPUT/FORWARD, `ipv6=block`) rejects IPv6 except
link-local/multicast, and rejects **global** IPv6 DNS. Link-local DNS is let
through on purpose: see the DNS note in the trap list. `ipv6=disable` installs no
IPv6 chain at all: it writes `disable_ipv6=1` (plus `accept_ra=0`, `autoconf=0`)
to every `/proc/sys/net/ipv6/conf/*` except `lo`, and `off`/`stop` puts the saved
values back. Caveat: IMS (VoLTE/VoWiFi) talks IPv6 over `rmnet` on some carriers,
so if calls stop working use `block` plus Android Private DNS (DoT) instead.

Routing: `ip rule add fwmark <fwmark> table 2027 pref 110` plus
`ip route add local default dev lo table 2027` (the same for `ip -6` in
`ipv6=proxy`).

### Ordering and Android-specific traps that were measured and fixed

- **`RETURN` instead of `ACCEPT` in the PREROUTING bypass** made the core's answer
  to a local app hit the `-i lo -j TPROXY` rule again: 25 236 `inbound packet
  connection` lines for one request. Bypass in `PREROUTING` is `ACCEPT`; in
  `OUTPUT` it must be `RETURN` so the vendor mangle chains still run.
- **A rejected IPv6 DNS can leave the phone with no resolver at all.** netd held
  `fe80::1%wlan0` plus `1.1.1.1`/`1.0.0.1`, and the IPv4 pair was marked `BROKEN`
  (18/24 and 24/24 timeouts, score 0, sample validity 1800 s). With `ipv6=block`
  rejecting IPv6 DNS, every name that was not already cached failed with
  `ping: unknown host` — 8/8 fresh names with the module running, 8/8 of the same
  names resolving with it stopped — while `nslookup <name> 1.1.1.1` from a root
  shell still answered in 25-270 ms through the hijack. Letting link-local DNS out
  turned that into 5/8 at once, healing as netd recovered. So `PISING_V6BLOCK`
  returns for `fe80::/10` *before* the DNS rejects: the price is a DNS leak to the
  LAN router, the alternative is no DNS.
- **Bypassing the core by SO_MARK alone** (`outbound.routing_mark`) does not stop
  the DNS transport from being captured; the gid bypass (`net_admin`, 3005) does.
  SO_MARK stays as a second guard only.
- **`-D` needs the full match spec**: `-D PREROUTING -p tcp -m socket -j X` does not
  match a rule inserted as `-m socket --transparent`, which left `PISING_DIVERT`
  behind on every stop.
- **KernelSU's installer does not extract `module.prop` for you** (`SKIPUNZIP=1`):
  `customize.sh` extracts it, otherwise `ksud module install` ends with
  `cp: can't stat …/module.prop`.

## Leak-free sing-box config (`config.json`)

`module/payload/config/config.json` is the config that ships with the module: a
complete, working file — mixed inbound on 127.0.0.1:7080, the TPROXY inbound on
1536, WireGuard endpoint, fakeip DNS, Clash API (9090), the API/dashboard on 9091,
two remote rule-sets (ads, telegram), a `find_process` route for three example
packages, and `Default_🦈` = direct for everything else. Its only placeholders are
the WireGuard credentials.

It is only used on a fresh install: `customize.sh` never overwrites an existing
`/data/adb/pi-sing/config/config.json`, so a real config on the phone survives
upgrades. Never commit real credentials — the shipped keys are 32 zero bytes in
base64 (`AAAA…AA=`), which `sing-box check` accepts and `run` starts with, the
tunnel simply never completes. To use your own keys, replace
`endpoints[0].private_key`, its `peers[0].public_key` and `peers[0].address`; to
use your own config, `cp` it over `config/config.json` and `su -c pi-sing start`.

Because `Default_🦈` is direct, a fresh flash keeps the phone online before the
keys are filled in; only the three example packages need the tunnel. Point
`Default_🦈` at the endpoint (or add it to the selector's `outbounds`) when
everything should be proxied — that is also the mode the notes below assume.

The self-test after `start` only proves that a proxied request succeeds, not that
it left through the tunnel: with `Default_🦈` = direct it passes on the carrier.

The shipped config already contains the five things TPROXY on Android needs. If
you write your own, keep the equivalent:

1. No `log.output` — the module redirects sing-box to
   `/data/adb/pi-sing/run/log/sing-box.log` (an `output` pointing at a directory
   that does not exist is fatal, and `check` does not catch it: it passes, then
   `run` dies with `start logger: open ...: no such file or directory`; `start`
   logs a warning when it sees the key). Every relative path in the config
   (`cache_file.path`, `services[].dashboard`) resolves inside
   `/data/adb/pi-sing/run/`, because `pi-sing` runs the core with
   `-D /data/adb/pi-sing/run`. The module leaves those values alone.
2. One `{"type": "tproxy"}` inbound; its `listen_port` is owned by
   `settings.ini` (`pi-sing start` rewrites it).
3. `route.default_domain_resolver` must be a **tunnel-side** DNS server, so every
   name the phone dials is resolved inside the tunnel. A `type: local` server does
   not work on Android (`read udp [::1]:53: connection refused`). The shipped
   config resolves through `remote_dns` (DoH to 8.8.8.8) over the default
   outbound; add `"detour": "Soul_🌐"` when everything should resolve inside the
   tunnel.
4. Remote rule-sets are initialized **before** the endpoint is up, so the HTTP
   client they use needs a working resolver: the shipped config gives them
   `http_clients: [{"tag": "direct-http", "version": 2}]` plus
   `route.default_http_client`/`default_domain_resolver`, which is what keeps
   startup from dying with `lookup github.com: WireGuard is not ready yet`.
5. The final selector defaults to the tunnel and `dns.servers[...].detour` points
   at that selector, so both traffic and DNS leave through the tunnel. Drop the
   fakeip IPv6 range when the tunnel carries IPv4 only (measured: an IPv6-only
   host fails through the proxy, while the phone's own IPv6 works).

A selector may be used as a DNS `detour`, a plain `direct` outbound may not
(`detour to an empty direct outbound makes no sense`).

## Changing the config

- Keep one `{"type": "tproxy"}` inbound; its `listen_port` is owned by
  `settings.ini`.
- The proxy outbounds do not need `routing_mark` (the gid bypass covers them),
  but adding it (`0x00400000`) is harmless.
- If you point DNS at a resolver that is only reachable inside the tunnel, keep
  `dns-bootstrap` available for rule-set downloads.
- After any edit: `su -c pi-sing restart` (or `iptables renew`).
- The module rewrites three values on start so `settings.ini` stays in charge:
  the tproxy inbound's `listen_port`, `outbound.routing_mark` (when present) and
  `log.level` (from `core_log_level`). Nothing else — `services[].dashboard` is
  sing-box's.

## License and vendored parts

GPL-3.0 (`LICENSE`), because this module ships and drives GPL-3.0 code:

- `META-INF/com/google/android/update-binary` is the unmodified Magisk
  `scripts/module_installer.sh` (topjohnwu/Magisk, GPL-3.0).
- sing-box (SagerNet/sing-box, GPL-3.0) is downloaded by
  `tools/fetch-sing-box.sh`; its `LICENSE` is kept next to the binary in
  `module/payload/` when built.
- Rule ordering was learned from `CHIZI-0618/AndroidTProxyShell` and
  `taamarin/box_for_magisk`; no code was copied from them.
