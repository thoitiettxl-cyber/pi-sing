# Layout

Repo and device side, and the three installer behaviours that were each bought
with a bug report.

## Repo

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
tests/netns-tproxy-test.sh    end-to-end in a throw-away netns (37 assertions:
                              TPROXY/DNS/per-app, an intranet destination stays
                              out of the blanket MARK, a `tailnet4` range is
                              captured instead of bypassed, hotspot ingress captured unless
                              it matches the uplink, PISING_DRY_RUN prints
                              without installing, ipv6=disable sets and restores
                              sysctls, an interface created after `on` inherits the
                              `default` template, `v6enforce` undoes what netd
                              turns back on)
tests/cli-test.sh             host, stub core: dashboard resolution (relative /
                              object / absolute), core_log_level, 🟢/🔴 description,
                              log split/rotation, watchdog vs a user stop, a decoy
                              process that mentions bin_path is not the core, a start
                              that brings a killed watchdog back exactly once,
                              services[].dashboard left alone, a failing name lookup
                              flagging run/dns.failed and the 🟠 DNS card while the
                              rules stay (38)
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

## On the device

Module scripts in `/data/adb/modules/pi-sing`, everything that can change in
`/data/adb/pi-sing`:

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

## `system/bin` symlinks, not wrapper files

The CLI is exposed through the module's `system/bin`, which the manager's mount
hook (Magisk magic mount, or the Hybrid Mount metamodule on this phone) overlays
onto `/system/bin` — the same shape as `/data/adb/modules/droidspaces` ->
`/system/bin/droidspaces` (a symlink into `/data`). Do not reintroduce wrapper
files in the data dir or in `/dev`: that was v1.5.0 and older, and the installer
now removes them. The symlink target is the data dir on purpose — the scripts are
replaced there by `update-core` and reinstalls without waiting for the mount.
Nothing in the module may depend on `pi-sing` being on PATH: `service.sh`,
`action.sh`, `customize.sh` and the installer call `$DATA/bin/pi-sing`.

## v1.0.0 settings.ini migration

The flat v1.0.0 layout is migrated by `customize.sh`, which appends the `*_dir`,
`log_dir` and `core_log_level` lines to an old `settings.ini` (existing values
untouched). Without the path block `pi-sing`/`pi.iptables` refuse to run —
deriving `bin_dir` on "/" would be a silent misconfiguration.

## The installer always prints the volume-key prompt

UP = check GitHub for a newer core, DOWN = keep the core already on the phone,
15 s no key = keep. Never make it conditional on anything: it was once
conditional and users reported the missing prompt as a bug. There is one zip and
it carries no core, so on a first flash "keep" means "still no core" (the
installer prints the update-core command). `PISING_INSTALL_CORE=1|0` answers
without a key and `PISING_KEY_WAIT=<s>` shortens the window (tests).

The wait is a **wall-clock deadline**, and the input queue is drained before the
prompt is printed. `getevent -lqc 1` returns on the first event of *any* kind and
this phone streams touch/nav events, so counting reads made the advertised 15 s
last ~2.4 s (measured: 5 reads = 787 ms); a volume key pressed to scroll the
manager log would answer a question the user has not read yet. Same shape as
`box_for_magisk` (`date +%s` deadline, drain in front of every prompt).

## `services[].dashboard` belongs to sing-box

**A relative `services[].dashboard` is resolved next to config.json** (never
against `-D run/`), an absolute path is used as is. `sync_dashboard` rewrites only
that value at start; the old `run/ui` copy is moved to `config/ui` by the
installer. Do not hardcode a ui/ directory anywhere.
