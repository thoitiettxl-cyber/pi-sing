# Tailscale endpoint, DNS and route rules

Added 2026-11-12 to the user's live config, on sing-box **1.14.4** (the version
the module ships). The android arm64 build from upstream is tagged
`with_tailscale`, so no custom build is needed: the doc pages linked below
describe a feature this binary already has.

Three separate things share the word "tailscale"; keep them apart:

| where | type | what it is |
| --- | --- | --- |
| `endpoints[]` | `tailscale` | the tailnet client (WireGuard + control plane + DERP) |
| `dns.servers[]` | `tailscale` | MagicDNS resolver bound to that endpoint by tag |
| `outbounds[]` | `tailcat` | the *other* thing — a client for a tailcat server, unrelated |

## Shape used in the live config

```json
"endpoints": [
  {
    "type": "tailscale",
    "tag": "Tailscale_🦎",
    "state_directory": "/data/adb/pi-sing/config/tailscale",
    "hostname": "pi-sing",
    "taildrop_directory": "/data/adb/pi-sing/config/Taildrop",
    "udp_timeout": "5m"
  }
]

"dns": {
  "servers": [
    { "type": "tailscale", "tag": "ts_dns", "endpoint": "Tailscale_🦎",
      "accept_search_domain": true }
  ]
}
```

and in `dns.rules`, **immediately before the fakeip rule**:

```json
{ "preferred_by": ["ts_dns"], "action": "route", "server": "ts_dns" }
```

and in `route.rules`, **after `sniff` and after the per-package rules, before
the blanket `network: [tcp, udp]` rule**:

```json
{ "preferred_by": ["Tailscale_🦎"], "action": "route", "outbound": "Tailscale_🦎" }
```

## Why the order is not free

- The DNS rule must sit **above the `fakeip` rule**. Measured 2026-11-12: with it
  above, `ping pi-sing.tailb5648f.ts.net` answers `100.119.98.112` (the node's real
  tailnet address). A tailnet name matched by the fakeip rule instead would come
  back as `198.18.x.x` and every connection to it would go to a fake address.
- `accept_search_domain: true` is what makes the **single-label** form work.
  Measured on the same config: `ping pi-sing` (no domain) → `100.119.98.112`.
  1.14.4's `tailnetDomains.match` only expands search domains when
  `expandSearchDomains` is set **and** `CountLabel(domain) == 1`, so without this
  flag only the FQDN resolves.
- The DNS rule needs a `preferred_by` **DNS server** tag (`ts_dns`), the route rule
  needs an **outbound/endpoint** tag (`Tailscale_🦎`). They are two different
  lookup paths in the code: `PreferredByDNSItem.Start` goes through the DNS
  transport manager, `PreferredByItem.Start` through the outbound manager.
- `tailb5648f.ts.net` (the tailnet name itself, no node label) is **not** a host
  and does not resolve — measured `ping: unknown host`. Use `<node>.<tailnet>.ts.net`.
- An endpoint can be used as an `outbound` tag in a route rule even though it is
  not in `outbounds[]`: `adapter/outbound/manager.go` `Outbound(tag)` falls back to
  `endpoint.Get(tag)`. Region 1.14.4, `route/rule/rule_item_preferred_by.go`
  resolves the same way, so `preferred_by: ["Tailscale_🦎"]` matches the tailnet
  peer addresses and MagicDNS names.

## `check` passes, `run` fails — the tags are checked at start

`sing-box check` validates shape only. Measured on the host with 1.14.4:

| config | `check` | `run` |
| --- | --- | --- |
| `preferred_by: ["nope_dns"]` in a DNS rule | `exit 0` | `FATAL start dns-router: initialize DNS rule[5]: DNS server not found: nope_dns` |
| `preferred_by: ["nope_ep"]` in a route rule | `exit 0` | `FATAL post-start router: initialize rule[7]: outbound not found: nope_ep` |
| `preferred_by: ["direct_dns"]` (an `https` server) | `exit 0` | `FATAL start dns-router: initialize DNS rule[5]: DNS server type does not support preferred_by: https` |

So a typo in a tag is not caught before the core is replaced on the phone. Run
`pi-sing check` and then watch the start, or run the candidate config on the host
with a rewritten `cache_file.path`, `services[].listen_port` and inbound port.

Only these DNS server types implement `preferred_by` (1.14.4 docs): `hosts`,
`local`, `mdns`, `tailscale`, `openconnect`, `resolved`. A DoH/DoT server cannot
be named there.

## Authentication: the login URL is `Info` under a `warn` config

No `auth_key` was set, so the endpoint logs a login URL and waits:

```
protocol/tailscale/endpoint.go: Waiting for authentication: <url>   (Info level)
```

The live config runs `log.level = "warn"` and `core_log_level=warn`, so that line
is **invisible** in `run/log/sing-box.log`. `scripts/services[].dashboard`
(`/data/adb/pi-sing/config/ui`) is the way in: Tools → Endpoints. The state file
is the proof of login without any UI:

```
/data/adb/pi-sing/config/tailscale/tailscaled.state     # base64 values
  _current-profile, _profiles   -> "LoggedOut": false, "Hostname": "pi-sing"
```

Measured 2026-11-12 on the phone: profile `237f` logged in (the account name is
personal — do not copy it into this repo), `MagicDNSName: tailb5648f.ts.net`,
`WantRunning: true`, node self IP `100.119.98.112`. The state directory is
created `root:net_admin 0700` (gid 3005, the core's group), so it must stay
writable by that gid.

`ping -c1 pi-sing` returning `0% packet loss` is **not** the expected check with
one node in the tailnet: the address resolves, nothing answers, because the only
member is this phone itself.

## Two constraints from the docs, not yet exercised here

- Only **one** Tailscale DNS server per endpoint: a second one fails with
  `only one Tailscale DNS server is allowed for single endpoint` (1.14.4
  `protocol/tailscale/dns_transport.go`).
- `on_demand` and `tailcat` are 1.15.0; `ssh_server`, `taildrop_directory` and
  `listen_port` are 1.14.0; `system_interface*`, `relay_server_port`,
  `advertise_tags` are 1.13.0. On 1.14.4 the config must not use `on_demand` —
  the field is absent from `option/tailscale.go` at that tag (verified in the
  v1.14.4 source), even though the binary string table contains the name.
- `system_interface` is deliberately **off**: this module is TPROXY-only by
  design (`README.md`), and a Tailscale TUN would be a second TUN next to none.

## Deliberately not added

- `auth_key` — the phone is already logged in; a key in the config would be a
  credential in a file this repo must never contain.
- `exit_node` — would reroute the whole tailnet path; the user's routing intent is
  three packages through `Soul_🌐` and everything else direct.
- `ssh_server` — opens a root-capable SSH endpoint (on Android every non-`root`
  user is resolved to a package UID). Add only on request.

## Source pages

- <https://sing-box.sagernet.org/configuration/endpoint/tailscale/>
- <https://sing-box.sagernet.org/configuration/dns/server/tailscale/>
- <https://sing-box.sagernet.org/configuration/dns/rule/> (`preferred_by`, 1.14.0)
- <https://sing-box.sagernet.org/configuration/route/rule/> (`preferred_by`, 1.13.0)
- <https://sing-box.sagernet.org/configuration/outbound/tailcat/> (not this)
