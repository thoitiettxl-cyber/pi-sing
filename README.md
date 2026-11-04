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
| traffic exit | `curl https://1.1.1.1/cdn-cgi/trace` | `ip=185.98.169.17 loc=US` (the WireGuard endpoint), not the carrier `＜carrier-ip＞` |
| DNS through the tunnel | `curl -o /dev/null -w '%{remote_ip}' https://www.wikipedia.org` | `198.18.0.32` — a sing-box **fakeip**, so the name was resolved by sing-box, not by Android |
| resolver as the outside world sees it | `curl -sL https://edns.ip-api.com/json` | `United States - Google LLC` (DNS-over-HTTPS inside the tunnel), not the ISP resolver it reported before the fix |
| IPv6 leak | `curl -6 https://ipv6.icanhazip.com` | fails (`rc=6`) and `PISING_V6BLOCK` rejects it; the phone's own `2402:800:…` address never reaches the network |
| QUIC | `iptables -t filter -S PISING_GUARD` | `udp 443`/`udp 80` rejected, so apps fall back to TCP through the proxy |
| container path | `curl https://api.ipify.org` from the Droidspaces Debian container | `＜carrier-ip＞` — bypassed, the container keeps its own path (and the operator's own access) |

Host-side tests, run on the same kernel:

```
tests/smoke-check.sh                  every script parses (dash), both configs pass `sing-box check` 1.14.4
tests/netns-tproxy-test.sh            14/14 — TCP, UDP/53 hijack, per-app blacklist + whitelist,
                                      core-gid bypass (no capture loop), clean teardown
tests/installer-test.sh               31/31 — fresh install, migration from the v1.0.0 flat
                                      layout (kept files, moved cache, appended paths),
                                      idempotent re-run, stale watchdog killed,
                                      old settings.ini rejected
```

Not verified: the `ipv6=proxy` mode (this tunnel carries IPv4 only — measured),
hotspot/tether capture (`ap.list.cfg`), and the first boot of the service on a
fresh reboot (the service was exercised by running `service.sh` directly).

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
tools/  build.sh            -> dist/Pi-Sing-<version>.zip
```

## Build

The sing-box binary is **not** committed (79 MiB, GPL-3.0 software from another
project). Fetch the pinned release first:

```
tools/fetch-sing-box.sh                 # arm64 default, --arch arm|arm64|x86_64|x86
SINGBOX_BIN=/path/to/linux/sing-box tests/netns-tproxy-test.sh
tools/build.sh                          # -> dist/Pi-Sing-<version>.zip + sha256
```

`tools/fetch-sing-box.sh` pins `sing-box 1.14.4` and verifies the tarball sha256.
`tools/build.sh` runs `tests/smoke-check.sh` first and refuses to build without
the binary.

On the device:

```
/data/adb/modules/pi-sing/      module.prop, service.sh, action.sh, uninstall.sh
/data/adb/pi-sing/              everything that changes, grouped by purpose
  settings.ini                  the only real file at the top: every knob
  bin/                          pi-sing, pi.iptables, sing-box, sing-box.LICENSE
  config/                       config.json, config.example.json
  lists/                        package.list.cfg, ap.list.cfg
  run/                          pid, logs, generated lists, sing-box cache.db
  pi-sing, pi.iptables          symlinks to bin/ (see the upgrade note)
/dev/pi-sing -> /data/adb/pi-sing/bin/pi-sing
```

`bin/` and `config/config.example.json` are replaced on upgrade; `settings.ini`,
`config/config.json` and the two files in `lists/` are kept. An install from the
old flat layout is moved into these directories by `customize.sh` (existing
values untouched), and an older `settings.ini` gets the `*_dir` block appended —
it does not have one, so the scripts would otherwise refuse to guess.

`pi-sing` and `pi.iptables` at the top of the data dir are symlinks into `bin/`
because the manager (measured with KernelSU 3.3.1) stages a module update in
`/data/adb/modules_update` and applies its `service.sh`/`action.sh` only on the
next boot: until then the previous boot script runs, and it calls
`/data/adb/pi-sing/pi-sing`. Without the link the module cannot start between an
in-app upgrade and a reboot. A watchdog loop from the previous version is killed
by the installer (SIGTERM then SIGKILL — the loop survives SIGTERM on this ROM).

## Usage

```
su -c /dev/pi-sing start        # run sing-box, install the rules, self-test
su -c /dev/pi-sing stop         # remove the rules, stop sing-box
su -c /dev/pi-sing restart
su -c /dev/pi-sing status
su -c /dev/pi-sing log 80
su -c /dev/pi-sing iptables off|on|renew|status
```

`action.sh` (manager action button) does the same toggle.

`start` runs a **self-test** after installing the rules: one request from a socket
the rules exempt (direct) and one the rules must capture (proxied). Direct OK +
proxied failing means the tunnel is down → rules stay (fail closed, no leak).
Both failing means the rules themselves are wrong → they are removed so the phone
keeps its connection. `selftest=0` disables it.

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
   `/data/adb/pi-sing/run/pi-sing.log` (an absolute path to a directory that does
   not exist on the phone is fatal). Likewise every relative path in the config
   (`cache_file.path`) resolves inside `/data/adb/pi-sing/run/`, because `pi-sing`
   runs the core with `-D /data/adb/pi-sing/run`.
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

## License and vendored parts

GPL-3.0 (`LICENSE`), because this module ships and drives GPL-3.0 code:

- `META-INF/com/google/android/update-binary` is the unmodified Magisk
  `scripts/module_installer.sh` (topjohnwu/Magisk, GPL-3.0).
- sing-box (SagerNet/sing-box, GPL-3.0) is downloaded by
  `tools/fetch-sing-box.sh`; its `LICENSE` is kept next to the binary in
  `module/payload/` when built.
- Rule ordering was learned from `CHIZI-0618/AndroidTProxyShell` and
  `taamarin/box_for_magisk`; no code was copied from them.
