# fix-cursor-proxy-bypass

A reversible macOS workaround for the Cursor `always-local-singleton` process bypassing the configured HTTP proxy and overriding `cursor.general.disableHttp2`.

中文：这是一个可逆的 macOS 临时修复方案，用于解决 Cursor `always-local-singleton` 绕过 `http.proxy`、直接连接 Cursor API，以及服务端覆盖 `cursor.general.disableHttp2` 的问题。

> [!WARNING]
> This is an unofficial workaround for affected Cursor releases before the official v3.11 fix. It modifies Cursor's local state database, not `Cursor.app`. Remove it after installing a release that contains the official fix.

## Affected behavior

The observed failure path is:

1. Cursor enables the `decompose_always_local_ext_host` feature gate.
2. AI traffic moves into the `always-local-singleton` utility process.
3. The process connects directly instead of using the configured `http.proxy`.
4. A server-provided HTTP/2 value can override the user's `cursor.general.disableHttp2: true`.
5. Corporate-proxy users may see timeouts, regional model errors, or an unexpectedly restricted model list.

Related report: [Cursor forum issue #164325](https://forum.cursor.com/t/bug-always-local-singleton-ignores-http-proxy-and-server-overrides-cursor-general-disablehttp2/164325).

## Validated environment

This workaround was successfully validated on 2026-07-09:

| Component | Validated value |
| --- | --- |
| Operating system | macOS 15.7.2 |
| Architecture | Apple Silicon (`arm64`) |
| Cursor | 3.10.20 |
| Proxy | Local HTTP proxy configured through Cursor `http.proxy`; endpoint omitted |

Validation covered:

- reproducing the enabled/effective singleton gate before repair;
- observing the `always-local-host` process and affected direct API connections;
- disabling the effective decomposition gate;
- confirming `always-local-host` no longer started;
- confirming the affected Cursor traffic used the configured loopback proxy;
- restarting Cursor and confirming the fix remained active;
- simulating a server write of `true` and confirming the gate remained `false`.

This is a validated workaround for the environment above, not a claim of compatibility with every Cursor build.

## Requirements

- macOS
- Cursor 3.9.16 through affected 3.10.x builds
- `/bin/sh`
- `sqlite3` with JSON functions

Do not apply the workaround blindly to Cursor v3.11 or later. Diagnose the live behavior first.

## Quick start

Clone the repository:

```sh
git clone https://github.com/Drswith/fix-cursor-proxy-bypass.git
cd fix-cursor-proxy-bypass
```

Inspect the current state while Cursor is running:

```sh
./scripts/cursor-proxy-workaround.sh status
```

Save your work and completely quit Cursor, then repair:

```sh
./scripts/cursor-proxy-workaround.sh repair
```

The script reopens Cursor after installing the workaround.

Expected status after startup:

```text
gate_value=0
trigger_count=2
always_local_singleton=stopped
cursor=running
```

## Commands

| Command | Behavior |
| --- | --- |
| `status` | Read-only inspection of the gate, triggers, singleton process, and loopback Cursor connections |
| `install` | Install the workaround; alias of `repair` |
| `repair` | Back up the affected row, disable the gate, install persistence triggers, and reopen Cursor |
| `remove` | Remove only the two workaround triggers |

`repair` and `remove` refuse to run while Cursor is open.

## How it works

Cursor 3.10.20 reads this gate from the Statsig bootstrap object stored under:

```text
ItemTable["workbench.experiments.statsigBootstrap"]
feature_gates["3795038140"].value
```

The hash `3795038140` corresponds to `decompose_always_local_ext_host` in the validated build.

Setting standalone database keys named `decompose_always_local_ext_host` and `cursor_extensions_isolation_v2` did not affect Cursor 3.10.20. The effective value came from the hashed Statsig cache.

The repair script:

1. saves a permission-restricted backup of the affected Statsig JSON row;
2. changes only the hashed decomposition gate to `false`;
3. installs narrow `AFTER UPDATE` and `AFTER INSERT` triggers that prevent only this gate from being restored to `true`;
4. removes the ineffective standalone overrides;
5. leaves the signed Cursor application bundle unchanged.

If the expected gate path is absent, the script stops without modifying the database.

## Verification

Database status alone is insufficient. Verify all of these after repair:

1. `status` reports `gate_value=0` and `trigger_count=2`.
2. The newest Cursor `renderer.log` contains:

   ```text
   decompose_always_local_ext_host gate is disabled, effective decomposition is disabled
   ```

3. No `always-local-host` process is running.
4. The affected API flow uses the configured proxy and no longer creates the original direct connection.

## Remove after the official fix

After installing a Cursor release containing the official fix:

1. Save work and completely quit Cursor.
2. Run:

   ```sh
   ./scripts/cursor-proxy-workaround.sh remove
   ```

3. Start Cursor normally and verify its proxy behavior.

Removing the triggers lets Cursor resume server-managed gate updates. It does not restore an old full database backup or overwrite newer Cursor state.

## Agent skill

The repository includes a reusable skill at:

```text
skills/fix-cursor-proxy-bypass/
```

Install it for Codex:

```sh
cp -R skills/fix-cursor-proxy-bypass \
  "${CODEX_HOME:-$HOME/.codex}/skills/"
```

Then invoke:

```text
$fix-cursor-proxy-bypass
```

The skill requires live diagnosis before mutation and requires the user to quit Cursor before repair or removal.

## Test

Run the fixture-based test without touching the real Cursor database:

```sh
./tests/test-workaround.sh
```

## Privacy

The repository contains no Cursor database, logs, authentication data, user-specific absolute paths, local usernames, or private proxy endpoint. Runtime backups remain local under Cursor's own `globalStorage` directory.

## License

[MIT](LICENSE)
