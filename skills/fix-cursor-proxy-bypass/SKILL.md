---
name: fix-cursor-proxy-bypass
description: Diagnose and repair the macOS Cursor 3.9.16-3.10.x always-local-singleton bug that bypasses http.proxy, ignores cursor.general.disableHttp2, makes direct api2.cursor.sh connections, causes regional model errors, or logs ClientHttp2Session timeouts. Use for installing, checking, reapplying, or removing the reversible local Statsig-gate workaround before Cursor v3.11.
---

# Fix Cursor Proxy Bypass

Diagnose the live network path first. Apply the bundled workaround only when the observed behavior matches this bug.

## Safety

- Target macOS Cursor 3.9.16-3.10.x. Check the installed version before changing state.
- Run `status` read-only while Cursor is open.
- Require Cursor to be completely closed before `repair` or `remove`. Ask the user to save work and quit; do not force-kill Cursor.
- Back up the affected Statsig row before mutation.
- Do not patch or re-sign `Cursor.app`.
- Stop if the expected gate is missing. Re-analyze the installed version instead of guessing another hash.

## Diagnose

1. Check the version, settings, proxy health, singleton process, sockets, and latest logs:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Cursor.app/Contents/Info.plist
rg -n 'http\.proxy|http\.proxySupport|cursor\.general\.disableHttp2' \
  "$HOME/Library/Application Support/Cursor/User/settings.json"
pgrep -fl 'always-local-host|alwaysLocalSingletonMain'
nc -vz -w 2 <proxy-host> <proxy-port>
```

2. Inspect the newest `renderer.log` and `alwaysLocalSingleton.log`. Treat these together as confirmation:
   - `decompose_always_local_ext_host gate is enabled`
   - `always-local-host` exists
   - Cursor connects directly to resolved Cursor API addresses instead of the configured local proxy
   - `ClientHttp2Session`, `ETIMEDOUT`, or regional model errors appear

3. Run the bundled read-only status command:

```sh
scripts/cursor-proxy-workaround.sh status
```

Resolve the script path relative to this `SKILL.md`.

## Repair

After the user has closed Cursor, run:

```sh
scripts/cursor-proxy-workaround.sh repair
```

The script:

- backs up `workbench.experiments.statsigBootstrap`;
- sets hashed gate `3795038140` (`decompose_always_local_ext_host`) to `false`;
- installs narrow update/insert triggers so a server refresh cannot restore this gate to `true`;
- removes ineffective direct-key overrides from older forum instructions;
- reopens Cursor.

## Verify

After startup, require all of the following:

- `status` reports `gate_value=0` and `trigger_count=2`;
- logs report `gate is disabled, effective decomposition is disabled`;
- no `always-local-host` process exists;
- Cursor connects to the configured proxy and no longer directly reaches the affected API destination.

Do not claim success from the database value alone.

## Remove

After confirming an official fixed release is installed, ask the user to quit Cursor and run:

```sh
scripts/cursor-proxy-workaround.sh remove
```

This drops only the two workaround triggers. The server resumes normal gate management on the next launch.

## Failure handling

- If a Cursor update recreates the state database, diagnose again before rerunning `repair`.
- If the gate path is missing, stop; the internal schema or hash changed.
- If the gate is disabled but singleton still starts, inspect fresh startup logs and do not add broader database triggers.
- If proxy traffic still fails with singleton absent, diagnose the proxy, DNS, certificates, and routing as a separate problem.
