# Testing

Every number below is an expected pass count, not a target. A mismatch is a
finding, not a flake.

## Host (this container; kernel has xt_TPROXY, `ip netns` works)

```
SINGBOX_BIN=/root/tmp/sbref/sing-box-1.14.4-linux-arm64/sing-box tests/smoke-check.sh
SINGBOX_BIN=... tests/netns-tproxy-test.sh          # 55/55 expected
tests/update-core-test.sh                           # 47/47 expected, no device
tests/installer-test.sh                             # 67/67 expected, no device
tests/cli-test.sh                                   # 61/61 expected, no device
tests/action-test.sh                                # 32/32 expected, no device
tools/build.sh                                      # smoke + the module zip (no core)
```

The netns test resolves through `100.100.100.100` unless `PISING_TEST_DNS` names
another resolver. Measured 2026-11-21 from this container (WiFi uplink) that
address timed out, and the three assertions that need a name (`curl -> 200`,
`connection entered tproxy-in`, `UDP/53 answered`) failed — on the previous
commit as well, 34/37, so it is the resolver and not the rules.
`PISING_TEST_DNS=1.1.1.1` gave 55/55.

The same test polls the rule set while `renew` runs and connects to the tproxy
port itself; on the rules of v1.8.6 those 13 assertions fail (a hook missing in
186 of 253 listings, IPv6 back on in 30 162 of 41 366 reads, the core reached
8 983 times by one self-dial).

## Device (root through android-bridge)

```
S=/run/android-bridge/bridge.sock            # may also appear as /run/android-bridge/android-bridge/bridge.sock
android-bridge -s $S -T su -c 'sh /data/local/tmp/x.sh'
android-bridge -s $S push ./local-file /data/local/tmp/local-file   # then su cp into /data/adb
```

## Touching rules on the live phone: one revert, one process

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

## Device check set

A useful device check set (all must hold):

| check | expectation |
| --- | --- |
| `curl -s https://1.1.1.1/cdn-cgi/trace` | proxy exit IP, not the carrier IP |
| `curl -o /dev/null -w '%{remote_ip}' https://www.wikipedia.org` | `198.18.x.x` (fakeip) = DNS goes through sing-box |
| `curl -sL https://edns.ip-api.com/json` | resolver is the tunnel-side one, not the ISP |
| `curl -6 https://ipv6.icanhazip.com` | fails |
| container `curl https://api.ipify.org` | carrier IP (bypassed) |
