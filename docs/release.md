# Release

1. Bump `version` and `versionCode` in `module/module.prop`.
2. `SINGBOX_BIN=... tools/build.sh` → `dist/Pi-Sing-<version>.zip` + sha256,
   module only. Nothing is pinned to a core release: the zip has none, and
   `update-core` follows GitHub's latest (the digest comes from the same API
   response when the asset has one; sing-box's tarballs do not, so that path
   warns and verifies by tag + `check`). A core in `module/payload/bin/` (from `tools/fetch-sing-box.sh`,
   needed by the host tests) is not copied into the zip.
3. Check the zip before publishing: `python3 -c "import zipfile;z=zipfile.ZipFile('<zip>');print(len(z.namelist()))"`
   must print **15** and the largest entry must be `payload/bin/pi-sing` (~32 KiB).
   A `config/ui/` directory inside `module/payload/config/` once shipped 6.7 MB of
   dashboard assets that way (v1.7.0); the dashboard belongs to sing-box and is
   downloaded at runtime, never committed.
4. `SINGBOX_BIN=... tests/netns-tproxy-test.sh` and the device check set in
   `docs/testing.md`. `tools/build.sh` already runs smoke + cli-test +
   action-test + installer-test.
5. Commit subject: `pi-sing: <what changed>`; body explains the measurement, not
   the intention.
