# Pi-Sing — agent guide

Magisk / KernelSU / APatch module that runs **only sing-box** as a transparent
proxy (TPROXY, TCP + UDP, no TUN) on a rooted Android phone. Not a generic
sing-box frontend: every rule here exists because of something measured on a real
device — see `README.md` for the story, `docs/` for the measurements.

**This file is the entry point and stays short.** Read it every time; open a
`docs/` file only when your task touches its topic (table below). Do not move
measurements back into this file.

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
   the bridge — the bridge is a unix socket, it works without a network. One
   armed revert at a time; details in `docs/testing.md`.
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

## Where the rest lives

| file | open it when |
| --- | --- |
| `docs/layout.md` | you touch `customize.sh`, `system/bin`, `settings.ini`, the zip contents, the volume-key prompt, `services[].dashboard` |
| `docs/rules.md` | you touch `pi.iptables`, `PISING_EXT`/`PISING_LOCAL`, DNS ordering, bypass, `ipv6=` modes, `ap.list.cfg` |
| `docs/testing.md` | before running tests, and before touching rules on the live phone |
| `docs/android-traps.md` | pids and the watchdog, `sing-box` DNS/`detour`, netd/IPv6, `update-core`, `check` vs `run` |
| `docs/device.md` | you need this phone's own numbers: hardware/ROM, the two SIMs and RAT, the WiFi 80→160 MHz country-code finding, the user's live config |
| `docs/tailscale.md` | you touch the `tailscale` endpoint, `ts_dns`, `preferred_by`, MagicDNS, or need the login/state facts |
| `docs/release.md` | you bump the version or build/publish the zip |

## Working on the device, in one breath

```
S=/run/android-bridge/bridge.sock
android-bridge -s $S push ./x.sh /data/local/tmp/x.sh
android-bridge -s $S -T su -c 'sh /data/local/tmp/x.sh'      # one command per su -c
/data/adb/pi-sing/bin/pi-sing status                          # the truth about ON/OFF
curl -4 -s https://api.ipify.org                              # in the container: carrier IP
```

Numbers in `docs/` are measurements with a date. Re-run the command next to a
number before you quote it.
