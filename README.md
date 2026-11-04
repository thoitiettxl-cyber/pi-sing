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

Measured with the module running (`su -c /dev/pi-sing status` → running, rules
installed, watchdog up):

| check | command | result |
| --- | --- | --- |
| traffic capture | `su -c /dev/pi-sing log core 200` while an app connects | `inbound/tproxy[tproxy-in]: inbound connection …` for the request; the outbound row then shows the config's chosen outbound (this config sends most rules through a `direct` tag, so the exit address is the carrier's) |
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
tests/cli-test.sh                     27/27 — dashboard resolution (relative/object/absolute),
                                      core_log_level, 🟢/🔴 description, log split, log rotation,
                                      watchdog leaves a user-stopped core stopped
tests/installer-test.sh               63/63 — fresh install, wrapper files (no symlinks),
                                      migration from the v1.0.0 flat layout, run/ui move,
                                      idempotent re-run, stale watchdog killed, volume-key
                                      prompt (+) / (-), thin zip with no core, failed
                                      download, old settings.ini rejected
tests/update-core-test.sh             29/29 — update-core against a fake release API: digest
                                      verified, swap + restart, "already latest" no-op,
                                      bad digest / failing `check` / dead core refused,
                                      previous binary restored and restarted, first core
                                      on a thin install (no previous binary)
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
          sing-box          the Android arm64 binary
    config/  config.json    sing-box config (see "leak-free config" below)
             config.example.json   minimal config: tproxy inbound + direct outbound
    lists/   package.list.cfg    per-app list (blacklist/whitelist)
             ap.list.cfg         interfaces whose incoming traffic is proxied
tests/  netns-tproxy-test.sh, smoke-check.sh, installer-test.sh
tools/  build.sh            -> dist/Pi-Sing-<version>.zip (full) / -thin.zip
```

## Build

The sing-box binary is **not** committed (79 MiB, GPL-3.0 software from another
project). Fetch the pinned release first:

```
tools/fetch-sing-box.sh                 # arm64 default, --arch arm|arm64|x86_64|x86
SINGBOX_BIN=/path/to/linux/sing-box tests/netns-tproxy-test.sh
tools/build.sh --all                    # -> dist/Pi-Sing-<version>[-thin].zip + sha256
```

`tools/fetch-sing-box.sh` pins `sing-box 1.14.4` and verifies the tarball sha256.
`tools/build.sh` runs `tests/smoke-check.sh` first and refuses to build the full
zip without the binary: 79 MiB unpacked, ~24 MB compressed, i.e. almost the whole
zip. `--thin` builds the same module without `payload/bin/sing-box` (23 KB
measured) for people who would rather download the core on the phone; `--all`
builds both.

On the device:

```
/data/adb/modules/pi-sing/      module.prop, service.sh, action.sh, uninstall.sh
/data/adb/pi-sing/              everything that changes, grouped by purpose
  settings.ini                  the only real file at the top: every knob
  bin/                          pi-sing, pi.iptables, sing-box, sing-box.LICENSE
  config/                       config.json, config.example.json
  lists/                        package.list.cfg, ap.list.cfg
  config/ui/                    dashboard served by services.api (created by sing-box)
  run/                          pid, stop intent, generated lists, sing-box cache.db
  run/log/                      module.log, sing-box.log (+.1 each)
  pi-sing, pi.iptables          real wrapper files that exec bin/ (no symlinks)
/dev/pi-sing                    real wrapper file, recreated by service.sh at boot
```

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
    (-) DOWN = keep the core in this zip / already on the phone
    no key   = keep
```

`(+)` runs the same `update-core` path as the CLI: the release comes from GitHub's
latest tag, the archive must match GitHub's sha256 digest, and the binary must
pass `check` with the live config. A failed download never aborts the flash — the
bundled or installed core stays and the log says why. `PISING_INSTALL_CORE=1|0`
answers without a key (unattended flashes, tests). With no `getevent` or `/dev/input`
in the installer context, the default (keep) is taken after printing the prompt.

The top-level `pi-sing` and `pi.iptables` are **real wrapper files** (a 3-line
`exec` into `bin/`), not symlinks: a backup/copy tool that drops links leaves a
working path, and `ls -l` shows a script. They exist because the manager (measured
with KernelSU 3.3.1) stages a module update in `/data/adb/modules_update` and
applies its `service.sh`/`action.sh` only on the next boot: until then the previous
boot script runs, and it calls `/data/adb/pi-sing/pi-sing`. `/dev/pi-sing` is a
real wrapper file too and is recreated by `service.sh` on every boot (its tmpfs is
empty after a reboot). A watchdog loop from the previous version is killed by the
installer (SIGTERM then SIGKILL — the loop survives SIGTERM on this ROM).

## Usage

```
su -c /dev/pi-sing start        # run sing-box, install the rules, self-test
su -c /dev/pi-sing stop         # remove the rules, stop sing-box (the watchdog stays down)
su -c /dev/pi-sing restart
su -c /dev/pi-sing status       # process, rules, dashboard path, log paths
su -c /dev/pi-sing log 80       # module.log (events)
su -c /dev/pi-sing log core 80  # sing-box.log (the core's own output)
su -c /dev/pi-sing iptables off|on|renew|status
su -c /dev/pi-sing update-core  # install the latest sing-box from GitHub
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
  `🔴 Stopped`, `🟠 Tunnel down - tap to stop` (rules stay, fail closed),
  `🟠 Rules off (selftest)`, `🔴 Config error`, `🔴 No core`,
  `🔴 Disabled (enabled=0)`, `⚪ Installed - reboot to start`.
  The watchdog only rewrites the file when the state changes.
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

sing-box serves the file server at `http://127.0.0.1:9091/dashboard/`. The path in
`config.json` is authoritative:

- a **relative** path is resolved **next to `config.json`** (`"ui"` →
  `config/ui`), never against `-D run/`; `../ui` puts it beside `config/`, an
  **absolute** path is used as is;
- if the directory is empty, sing-box downloads its official dashboard into it
  (needs network once, ~8 MB);
- an existing directory without sing-box's `.etag` is treated as user-provided and
  is served without auto-update.

`pi-sing start` rewrites only that one value (string or `{"path": …}` form) when it
is relative, so the folder really lives where `config.json` says. The installer
moves a dashboard left in `run/ui` by the old `-D run/` resolution to `config/ui`
once, instead of downloading it again. `pi-sing status` prints the resolved path.

`start` runs a **self-test** after installing the rules: one request from a socket
the rules exempt (direct) and one the rules must capture (proxied). Direct OK +
proxied failing means the tunnel is down → rules stay (fail closed, no leak), and
the card says `🟠 Tunnel down - tap to stop`: the phone is offline until the
tunnel is fixed or the proxy is turned off. `run/selftest.failed` records that
state, so the watchdog cannot repaint the card `🟢`; the next start that passes
clears it. Both failing means the rules themselves are wrong → they are removed
so the phone keeps its connection. `selftest=0` disables it.

## Updating the core

`pi-sing update-core` installs the latest sing-box release; the module does not
have to be rebuilt or reinstalled.

- the release comes from `api.github.com/repos/SagerNet/sing-box/releases/latest`,
  and the asset name follows `ro.product.cpu.abi` (`arm64-v8a` -> `android-arm64`,
  `armeabi-v7a` -> `android-arm`, `x86_64` -> `amd64`, `x86` -> `386`);
- the archive must match the `sha256` digest GitHub publishes for that asset, so a
  broken download or a proxy that rewrites the body is rejected;
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
| `ipv6` | `block` | `proxy` = proxy IPv6 too; `block` = reject IPv6 (no leak); `off` = leave it alone (leaks). `true`/`false` are aliases of `proxy`/`block` |
| `quic` | `disable` | reject UDP 443/80 so apps fall back to TCP |
| `proxy_mode` | `blacklist` | `blacklist` = proxy everything except listed apps; `whitelist` = only listed apps |
| `bypass_interfaces` | `ds-br+ ds-v+ vgate0 dummy0` | incoming interfaces that are never touched (Droidspaces bridges, VM gateway) |
| `ignore_interfaces` | empty | output interfaces that are never proxied |
| `core_user`/`core_group`/`core_gid` | `root`/`net_admin`/`3005` | the core runs as this uid:gid so its own traffic can be bypassed by gid |
| `core_log_level` | `warn` | level written into `config.json` at start; `config`/empty leaves the file in charge. `warn` keeps one line per connection out of the log |
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
link-local/multicast, and rejects IPv6 DNS so netd falls back to its IPv4
resolvers, whose queries the IPv4 chain hijacks.

Routing: `ip rule add fwmark <fwmark> table 2027 pref 110` plus
`ip route add local default dev lo table 2027` (the same for `ip -6` in
`ipv6=proxy`).

### Ordering and Android-specific traps that were measured and fixed

- **`RETURN` instead of `ACCEPT` in the PREROUTING bypass** made the core's answer
  to a local app hit the `-i lo -j TPROXY` rule again: 25 236 `inbound packet
  connection` lines for one request. Bypass in `PREROUTING` is `ACCEPT`; in
  `OUTPUT` it must be `RETURN` so the vendor mangle chains still run.
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

`module/payload/config/config.json` is a **template**: a WireGuard endpoint with
dummy keys and `203.0.113.10` as the peer, fakeip DNS, a Clash API, two remote
rule-sets. It is only used on a fresh install — `customize.sh` never overwrites an
existing `/data/adb/pi-sing/config/config.json`, so a real config on the phone is
kept across upgrades. Never commit real credentials.

The template already contains the five things TPROXY on Android needs. If you
write your own config, keep the equivalent:

1. No `log.output` — the module redirects sing-box to
   `/data/adb/pi-sing/run/log/sing-box.log` (an `output` pointing at a directory
   that does not exist is fatal). Every other relative path in the config
   (`cache_file.path`, `services[].dashboard` if you leave it relative before the
   first start) resolves inside `/data/adb/pi-sing/run/`, because `pi-sing` runs
   the core with `-D /data/adb/pi-sing/run`; the module rewrites only the
   dashboard path, relative to `config/`.
2. One `{"type": "tproxy"}` inbound; its `listen_port` is owned by
   `settings.ini` (`pi-sing start` rewrites it).
3. `route.default_domain_resolver` must be a **tunnel-side** DNS server, so every
   name the phone dials is resolved inside the tunnel. A `type: local` server does
   not work on Android (`read udp [::1]:53: connection refused`).
4. Give `http_clients` a `detour` plus a `domain_resolver` (a plain direct
   resolver such as `{"type":"udp","server":"8.8.8.8"}`): remote rule-sets are
   initialized **before** the endpoint is up, otherwise startup dies with
   `lookup github.com: WireGuard is not ready yet`. Only rule-set downloads use
   that path.
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
- After any edit: `su -c /dev/pi-sing restart` (or `iptables renew`).
- The module rewrites three values on start so `settings.ini` stays in charge:
  the tproxy inbound's `listen_port`, `outbound.routing_mark` (when present) and
  `log.level` (from `core_log_level`); plus a **relative** `services[].dashboard`
  path, which becomes absolute under `config/`.

## License and vendored parts

GPL-3.0 (`LICENSE`), because this module ships and drives GPL-3.0 code:

- `META-INF/com/google/android/update-binary` is the unmodified Magisk
  `scripts/module_installer.sh` (topjohnwu/Magisk, GPL-3.0).
- sing-box (SagerNet/sing-box, GPL-3.0) is downloaded by
  `tools/fetch-sing-box.sh`; its `LICENSE` is kept next to the binary in
  `module/payload/` when built.
- Rule ordering was learned from `CHIZI-0618/AndroidTProxyShell` and
  `taamarin/box_for_magisk`; no code was copied from them.
