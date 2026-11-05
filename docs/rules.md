# Rule contract (do not reorder without re-measuring)

`PISING_EXT` in mangle `PREROUTING`: bypass interfaces → DNS (53 tcp/udp) TPROXY →
`PISING_BYPASS` (**ACCEPT**) → `-i lo` TPROXY → `ap.list.cfg` interfaces TPROXY.

`PISING_LOCAL` in mangle `OUTPUT`: core gid RETURN → own_mark RETURN →
`ignore_interfaces` RETURN → DNS MARK → intranet/local `RETURN` **inline in this
chain** → per-app → blanket MARK.

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
