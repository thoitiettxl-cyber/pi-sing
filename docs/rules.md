# Rule contract (do not reorder without re-measuring)

`PISING_EXT` in mangle `PREROUTING`: bypass interfaces → DNS (53 tcp/udp) TPROXY →
`PISING_BYPASS` (**ACCEPT**) → `-i lo` TPROXY → `ap.list.cfg` interfaces TPROXY.

`PISING_BYPASS` and the intranet `RETURN` below both carry the same list:
`intranet4` minus `tailnet4` (settings.ini). A range listed in `tailnet4` is
captured like a public destination instead of bypassed — see "A tunnel range"
at the end of this file.

`PISING_LOCAL` in mangle `OUTPUT`: core gid RETURN → own_mark RETURN →
`ignore_interfaces` RETURN → DNS MARK → intranet/local `RETURN` **inline in this
chain** → per-app → blanket MARK.

`PISING_INPUT` in mangle `INPUT`, **first rule of the chain**: tcp/udp to
`tproxy_port` without the fwmark → `DROP`. IPv4 and IPv6, in every `ipv6=` mode.

Why it must stay this way (each measured — see README):

- `ACCEPT` in PREROUTING bypass, `RETURN` in OUTPUT bypass. Anything else either
  loops the core's own answers (25k `inbound packet connection` lines for one
  request) or skips the vendor mangle chains behind us (`qcom_NWMGR`,
  `oplus_tos_mapping`, `connmark_*`).
- The OUTPUT `RETURN`s must be written **into `PISING_LOCAL`**, not into a chain
  it jumps to: a `RETURN` inside a user chain only resumes the caller, so the
  intranet ranges fell through to the blanket MARK and every LAN connection from
  the phone was proxied (measured 2026-11-05: TCP to a LAN printer,
  `192.168.1.100:9100`, stayed `SYN_SENT`/`UNREPLIED` in conntrack while the
  rules were up and connected the moment `pi-sing stop` ran; the PREROUTING
  `ACCEPT` was never affected, which is why hotspot clients worked). An intranet
  address whose check-box is a sub-chain is a bug even if the rules "look
  right" — `tests/netns-tproxy-test.sh` now counts packets on the blanket MARK.
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

## Nothing but TPROXY reaches the tproxy port (measured 2026-11-21)

The tproxy inbound listens on every address (`"listen": "::"`). A connection made
*to* the port has the port itself as its destination, so the core dials it — which
is itself — and every dial is the next inbound connection.

| probe, netns + sing-box 1.14.4 + the rules of v1.8.6 | result |
| --- | --- |
| one TCP connection from a LAN neighbour to `<phone>:1536`, held 1 s | ~30 s of looping: 110 878 fds, 37.5 CPU-seconds, RSS 26 → 265 MiB |
| one UDP datagram from a LAN neighbour | 19 307 `inbound packet connection` lines in 5 s, 4 104 fds, still going |
| an app on the phone → the phone's own LAN address, or `[::1]` (`ipv6=disable`) | same loop |
| the same probes with `PISING_INPUT` | fds stay at 8, 0 inbound lines |

The `-d 127.0.0.1` rule in `PISING_GUARD` (filter `OUTPUT`) covers none of those.
A packet that TPROXY delivered carries the fwmark (`--tproxy-mark`, or the MARK in
`PISING_DIVERT`) and still has the destination the app asked for, so "to the
tproxy port **and** not marked" is exactly a connection to the listener itself. A
proxied connection to `<somewhere>:1536` is marked and passes (asserted for a
local app and for a hotspot client).

- It is in **mangle** `INPUT` and it is the **first** rule there, which is why it
  is a `DROP` (mangle has no `REJECT`): netd rewrites the mark of everything that
  arrives on an interface it manages before the filter table sees it. Read on the
  device: `-A routectrl_mangle_INPUT -i wlan0 -j MARK --set-xmark
  0x300cd/0x7fefffff`, one rule per interface, and that mask covers the fwmark bit
  `0x200000`. The same test as a `REJECT` in filter `INPUT` made a hotspot
  client's proxied connection to port 1536 fail (measured in a netns with that
  netd rule in place); first in mangle `INPUT` it connects.
- The IPv6 side exists in **every** `ipv6=` mode: the inbound is dual-stack
  whatever the module does about IPv6, and `ipv6=disable` leaves `::1` up.
- The hooks are re-inserted at the top by every `on`/`renew`, so a rule somebody
  else inserts above them does not stay there.

## `on`/`renew` is one commit per table (measured 2026-11-21)

`on` used to remove every rule and then build the set again, one `iptables` call
per rule (108 of them). `module.log` on the device, 2026-11-16..21 (5.25 days):
91 rebuilds, the rules gone for a median of 4 s, p90 14 s, 63 s at worst — 128 s
a day in which IPv4 left unproxied, port 53 was not hijacked and, with
`ipv6=disable`, the IPv6 stack was switched back on, each time right after the
network had changed.

Now the builders record their rules and `ip[6]tables-restore --noflush` (what
netd itself uses) commits each table once: the chains named in the batch are
created or flushed and refilled, the module's hooks are deleted (every
occurrence, so a doubled one is single again) and put back on top, in the same
commit. `ipv6=disable` no longer puts the stack back before disabling it again:
a renew only re-disables what netd turned on.

| | before | now |
| --- | --- | --- |
| listings of the mangle table during 5 renews that lacked a hook (host netns) | 350 of 572 | 0 of 204 |
| same on the phone, 3 renews in a private netns (`unshare -n`) | 357 of 451 | 0 of 110 |
| reads of `disable_ipv6` during 3 renews that found IPv6 on (`ipv6=disable`, host netns) | 28 658 of 46 534 | 0 of 11 318 |
| one renew on the phone, private netns, median of 6, three paired runs | 4.1–4.3 s | 0.94–1.0 s |

(The timing is old and new alternating in the same private netns at load average
7–8; a private netns has none of the vendor chains, so the live table costs both
more. On the phone `ipv6=disable` gave 0 of 34 968 reads with IPv6 on.) The
resulting rule set is line for line the one the old build produced, plus
`PISING_INPUT` — diffed for `block`, `disable`, `off`, `proxy` and whitelist +
`tailnet4` on the host, and for `block` on the phone.

- `run/rules.ipv6` records the `ipv6=` mode the last `on` installed. No file (a
  first `on`, or rules left by an older version): everything is removed first.
  Another mode: only the IPv6 side of the old mode goes. Same mode: nothing is
  removed. `off` deletes the file.
- A table that refuses its batch gets the old path — remove everything, then one
  rule at a time — with `falling back to the rule-by-rule build` in
  `module.log`. That is the previous behaviour, gap included, so it cannot be
  worse than before on a ROM whose `iptables-restore` misbehaves.
- `xt_socket` is not in every kernel and one unknown match fails a whole batch,
  so the `PISING_DIVERT` hook joins the batch only once it exists; the first time
  it is inserted on its own, as before.

## A tunnel range must leave both bypass lists (measured 2026-11-12)

`100.64.0.0/10` is on `intranet4` because it is shared address space, and that is
right for a LAN. It is wrong for a tailnet: the sing-box `tailscale` endpoint
carries `100.64.0.0/10` peers, and both bypass rules together made every peer
unreachable from the phone *and* from the container.

| state | phone → peer (ssh banner) |
| --- | --- |
| as shipped (RETURN in `PISING_LOCAL` + ACCEPT in `PISING_BYPASS`) | timeout |
| OUTPUT `RETURN` removed only | timeout |
| PREROUTING `ACCEPT` removed only | timeout |
| both removed | `SSH-2.0-OpenSSH_10.0p2 Debian-7+deb13u4` |

Why either half alone is not enough: `RETURN` in `OUTPUT` leaves the packet
unmarked, so `ip rule fwmark` never sends it to lo and the kernel picks the
uplink route (`ip route get 100.64.0.1` → `via 10.94.171.81 dev rmnet_data3`);
`ACCEPT` in `PREROUTING` then keeps the peer's answer from re-entering the
tunnel. At the same time the peer's own control-plane view looked healthy — its
`LastHandshake` and `RxBytes` moved — which is what made it look like a client
bug. That handshake belongs to the *endpoint inside sing-box* (a WireGuard
session over UDP to DERP), not to the phone's own TCP.

The fix is a knob, not a hard-coded edit: `tailnet4` in `settings.ini` lists the
ranges to capture, the other intranet ranges keep their `RETURN`/`ACCEPT`.
Empty by default, so a phone without a tunnel endpoint keeps the LAN
`RETURN`s exactly as before.
