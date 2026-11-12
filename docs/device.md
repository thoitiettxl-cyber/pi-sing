# This phone, and the user's own setup

Facts here are **measurements with a date**, taken on the real device. They age:
re-run the command before quoting a number. Nothing in this file is a rule about
the module — the module's rules are in `AGENTS.md`; this is the environment those
rules run in, plus the choices that belong to the user.

## Hardware / ROM

| | |
| --- | --- |
| model / device | `CPH2747` / `OP611FL1` (OnePlus, `ro.soc.model=SM8850`) |
| build | `CPH2747_17.0.0.102(EX01)`, ColorOS 17, Android 17, kernel 6.12 |
| region | `ro.oplus.pipeline.region=ROW`, `my_region` `ROW_all`, `persist.sys.oplus.region=VN` |
| root | KernelSU 3.3.1 + Hybrid Mount (overlays `module/system/bin` onto `/system/bin`) |
| history | China-market unit → paid SIM unlock → OxygenOS → ColorOS 17 international |

The import/unlock history shows up in **no** WiFi or RAT symptom measured so
far (2026-11-05): the WiFi regulatory domain comes from the SIM, not from the
unit's origin (`## WiFi` below), and both SIMs register `HOME`, not roaming.

## Network: two SIMs (measured 2026-11-05)

| | SIM 0 — **Vinaphone** | SIM 1 — Viettel |
| --- | --- | --- |
| role | **the data SIM** (`mActiveDataSubId=3`) | voice only |
| RAT | LTE **Band 3 / 1800 MHz / 20 MHz**, no CA | LTE B3 + ENDC |
| signal | RSRP **-98**, RSRQ -10, RSSNR 6 | RSRP **-93** |
| NR | `isNrAvailable=false`, `isEnDcAvailable=false` | `isNrAvailable=true`, `isEnDcAvailable=true` |
| 11 min of radio log | `Endc: false` **46/46** samples | `Endc: true` **41/41** samples |

- The **5G icon belongs to the Viettel line**, not to the SIM carrying data. In
  this area the data SIM never had NR.
- Throughput on the data SIM with WiFi off: **9.0–10.1 MB/s (72–80 Mbps)**,
  RTT avg **58 ms** (46–72, jitter 9 ms), 0% loss. That is the 4G ceiling of a
  20 MHz B3 carrier without CA, not a fault.
- **The 4G↔5G icon flapping is ColorOS "Smart 5G", by design.** The policy is a
  setting, not a prop: `settings list global | grep smart5g` →
  `oplus.radio.smart5g_basic_cfg=... scg_add_speed=2048; dis_endc_timer=30;
  screen_off_only_enable=1; wificonnect_prohibit=1; lowbat_heavy_enable=1;
  lowbat_thres=20 ...`. It adds the NR leg above ~2 Mbps and **releases it 30 s
  later**, or when the screen is off, the battery is under 20%, or WiFi is up.
  Tell the user to turn **Smart 5G** off if the toggling itself causes stalls; do
  not go looking for a modem fault.

Re-measure:

```
sh -c 'getprop gsm.network.type; dumpsys telephony.registry | grep -oE "isNrAvailable = (true|false)|isEnDcAvailable = (true|false)|mBands=\[[0-9]+\]|mChannelNumber=[0-9]+"'
curl -4 -o /dev/null -m 20 -s -w '%{speed_download} B/s\n' "https://speed.cloudflare.com/__down?bytes=25000000"
logcat -b radio -d | grep -F "endc state"   # phone 0 = Vinaphone, phone 1 = Viettel
```

## WiFi: why 160 MHz needs a different country code (measured 2026-11-05)

The home AP is `KSHT 5G` on **channel 116 = 5580 MHz** (the DFS band
5470–5725 MHz), 160 MHz, 2×2 HE.

1. Android takes the WiFi country code from the **mobile network**:
   `WifiCountryCode.initializeTelephonyCountryCodeIfNeeded()` →
   `mTelephonyManager.getNetworkCountryIso()`. Boot sequence captured in
   `dumpsys wifi`: driver default `US` → `VN` (from the SIM's `vn`) → `FR`.
2. wireless-regdb caps **every** 5 GHz range of `country VN` at 80 MHz
   (`(5490 - 5730 @ 80), (24), DFS`); `country FR` has
   `(5470 - 5725 @ 160), (500 mW), DFS`. A May-2025 patch adding `AUTO-BW` and
   6 GHz to VN is **not** in master (checked 2026-11-05).
3. A/B on this phone, fresh association each time, same SSID/channel/RSSI ≈ -30:
   **VN → 1200 Mbps (80 MHz)**, **FR → 2401 Mbps (160 MHz)**, twice each way;
   `cmd wifi force-country-code disabled` → back to VN → 1200 Mbps.
4. The user fixes this with their own Magisk module
   `/data/adb/modules/weather_wf_fr` — its whole `service.sh` is
   `cmd wifi force-country-code enabled FR` after boot, logging to
   `/data/local/tmp/wifi_country.log`. **It is the user's module, not this
   project's:** never edit, disable or "improve" it, and do not move the trick
   into pi-sing.
5. Cost of lying about the domain, so nobody "optimises" it later: FR gives
   **25 mW** on 5725–5875 MHz (channels 149–165) where VN gives 1 W; 5150–5350 is
   `NO-OUTDOOR`; 6 GHz is only the EU low band 5925–6425 (HAL reports 6g
   channels under FR, an **empty** list under VN). With a ~240 Mbps internet line
   the 80→160 MHz gain shows only on LAN transfers — the visible difference is
   the link rate in WiFi settings.

Re-measure:

```
cmd wifi force-country-code enabled VN; svc wifi disable; sleep 3; svc wifi enable; sleep 22
dumpsys wifi | grep -oE 'mCountryCodeFromDriver[A-Z]+' | tail -1
cmd wifi status | grep -oE 'Frequency: [0-9]+MHz|Link speed: [0-9]+Mbps'
```

## The user's live config — report, do not "fix"

The live file is `/data/adb/pi-sing/config/config.json` (0600). A JSON the user
hands over from `/storage/emulated/0/Download/config.json` is a **staging copy**:
edit and `check` it there, then it is imported. Compare the two after an import —
`ls -la` both and diff the sizes before assuming which one the core runs.

Read from `/data/adb/pi-sing` on 2026-11-05:

- `proxy_mode=blacklist`, `package.list.cfg` has **no** entries, `quic=disable`,
  `ipv6=disable`, `core_log_level=warn`, `watchdog=1`.
- `route.final` = `Default_🦈`, a selector holding only `Direct_🦈` → app traffic
  leaves **direct**.
- Exactly three packages are tunneled via `Soul_🌐` → `Proton-US_🔒`:
  `com.facebook.aura`, `mark.via.gp55`, `mark.via.gxr` (**Via browser**). The
  endpoint `79.127.185.251` measured **180–200 ms** (avg 193). So "browsing is
  slow" on Via is the tunnel, not the RAT — say so, and only re-route if asked.
- `remote_dns` = DoH `8.8.8.8` **with** `detour: Soul_🌐` (kept on purpose, see
  `android-traps.md`); `direct_dns` = DoH `1.1.1.1` without a detour and is the
  `route.default_domain_resolver`.
- **Never move the endpoint into the `all` list of the direct selector.** That
  separation is the user's, by design.
- **A Tailscale endpoint + MagicDNS were added on 2026-11-12** and are part of
  that same "report, do not fix" set: `endpoints[]` tag `Tailscale_🦎`
  (`state_directory=/data/adb/pi-sing/config/tailscale`, `hostname=pi-sing`),
  DNS server `ts_dns`, and two `preferred_by` rules. Verified on the phone the
  same day: state logged in (`LoginName` redacted in this repo), tailnet
  `tailb5648f.ts.net`, self IP `100.119.98.112`, `ping pi-sing` resolves. Shape,
  ordering, and the `check`-passes-`run`-fails traps: `docs/tailscale.md`.
- Switching WiFi off/on (uplink `wlan0` ↔ `rmnet_data2`) produces a ~5 s burst of
  `lookup ... dial tcp 1.1.1.1:443: i/o timeout` in `sing-box.log`; it heals by
  itself (measured 12:52:53, fine at 12:55:57). Not a module bug.
- Container sanity check: `curl -4 -s https://api.ipify.org` must print the
  phone's **carrier** address (Vinaphone `113.185.74.92` with WiFi off). A tunnel
  IP there means the bypass broke.

## Dev container

- Debian container on the phone (Droidspaces); it **shares the phone's PID
  namespace** (see `android-traps.md`).
- android-bridge socket: `/run/android-bridge/bridge.sock`.
- One command per `su -c`. A `;`-separated `su -c 'a; b'` silently runs in the
  shell domain, where `/data/adb/pi-sing` and `run/log/*` answer
  `Permission denied` (measured 2026-11-05) — push a script and run
  `su -c 'sh /data/local/tmp/x.sh'`.
