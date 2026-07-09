# fix-cursor-proxy-bypass

简体中文 | [English](README.en.md)

一个可逆的 macOS 临时修复方案，用于解决 Cursor `always-local-singleton` 绕过已配置的 HTTP 代理，以及覆盖 `cursor.general.disableHttp2` 的问题。

> [!WARNING]
> 这是针对 Cursor 官方 v3.11 修复发布前受影响版本的非官方 workaround。它会修改 Cursor 的本地状态数据库，但不会修改 `Cursor.app`。安装包含官方修复的版本后，请移除此 workaround。

## 受影响行为

实测故障链如下：

1. Cursor 启用 `decompose_always_local_ext_host` feature gate。
2. AI 流量被转移到 `always-local-singleton` utility process。
3. 该进程直接连接网络，没有使用已配置的 `http.proxy`。
4. 服务端下发的 HTTP/2 配置可能覆盖用户设置的 `cursor.general.disableHttp2: true`。
5. 使用企业代理的用户可能遇到超时、区域模型错误，或者模型列表异常受限。

相关报告：[Cursor forum issue #164325](https://forum.cursor.com/t/bug-always-local-singleton-ignores-http-proxy-and-server-overrides-cursor-general-disablehttp2/164325)。

## 已验证环境

此 workaround 已于 2026-07-09 在以下环境中验证成功：

| 组件 | 已验证版本 |
| --- | --- |
| 操作系统 | macOS 15.7.2 |
| 架构 | Apple Silicon（`arm64`） |
| Cursor | 3.10.20 |
| 代理 | 通过 Cursor `http.proxy` 配置的本地 HTTP 代理；端点已省略 |

验证内容包括：

- 修复前成功复现 singleton gate 处于 enabled/effective 状态；
- 观察到 `always-local-host` 进程和受影响 API 的直接连接；
- 禁用实际生效的 decomposition gate；
- 确认 `always-local-host` 不再启动；
- 确认受影响的 Cursor 流量改为使用已配置的 loopback 代理；
- 重启 Cursor 后确认修复仍然有效；
- 模拟服务端将 gate 写回 `true`，确认 gate 仍保持 `false`。

以上结论表示该 workaround 已在表格中的环境验证成功，不代表兼容所有 Cursor 构建版本。

## 环境要求

- macOS
- Cursor 3.9.16 至受影响的 3.10.x 版本
- `/bin/sh`
- 支持 JSON 函数的 `sqlite3`

不要在 Cursor v3.11 或更高版本上盲目应用此 workaround。请先诊断实际网络行为。

## 快速开始

克隆仓库：

```sh
git clone https://github.com/Drswith/fix-cursor-proxy-bypass.git
cd fix-cursor-proxy-bypass
```

Cursor 运行时，可以只读检查当前状态：

```sh
./scripts/cursor-proxy-workaround.sh status
```

保存工作并完全退出 Cursor，然后执行修复：

```sh
./scripts/cursor-proxy-workaround.sh repair
```

安装 workaround 后，脚本会重新打开 Cursor。

启动后的预期状态：

```text
gate_value=0
trigger_count=2
always_local_singleton=stopped
cursor=running
```

## 命令

| 命令 | 行为 |
| --- | --- |
| `status` | 只读检查 gate、触发器、singleton 进程和 Cursor loopback 连接 |
| `install` | 安装 workaround；等同于 `repair` |
| `repair` | 备份受影响的数据行、禁用 gate、安装持久化触发器并重新打开 Cursor |
| `remove` | 仅删除 workaround 创建的两个触发器 |

Cursor 仍在运行时，`repair` 和 `remove` 会拒绝执行。

## 工作原理

Cursor 3.10.20 从以下 Statsig bootstrap 对象读取此 gate：

```text
ItemTable["workbench.experiments.statsigBootstrap"]
feature_gates["3795038140"].value
```

在已验证构建中，哈希值 `3795038140` 对应 `decompose_always_local_ext_host`。

直接在数据库中写入名为 `decompose_always_local_ext_host` 和 `cursor_extensions_isolation_v2` 的独立键，对 Cursor 3.10.20 不生效。实际值来自经过哈希的 Statsig 缓存。

修复脚本会：

1. 使用受限文件权限备份受影响的 Statsig JSON 数据行；
2. 仅将经过哈希的 decomposition gate 改为 `false`；
3. 安装范围严格限定的 `AFTER UPDATE` 和 `AFTER INSERT` 触发器，防止服务端仅将此 gate 恢复为 `true`；
4. 删除不生效的独立 override；
5. 保持已签名的 Cursor 应用包不变。

如果预期的 gate 路径不存在，脚本会停止执行，不会修改数据库。

## 验证

只检查数据库值不足以证明修复成功。修复后请确认以下全部条件：

1. `status` 输出 `gate_value=0` 和 `trigger_count=2`。
2. 最新的 Cursor `renderer.log` 包含：

   ```text
   decompose_always_local_ext_host gate is disabled, effective decomposition is disabled
   ```

3. 不存在 `always-local-host` 进程。
4. 受影响的 API 流量经过已配置的代理，不再产生原始直接连接。

## 官方修复发布后移除

安装包含官方修复的 Cursor 版本后：

1. 保存工作并完全退出 Cursor。
2. 运行：

   ```sh
   ./scripts/cursor-proxy-workaround.sh remove
   ```

3. 正常启动 Cursor 并验证代理行为。

删除触发器后，Cursor 会在下次启动时恢复由服务端管理 gate。该操作不会恢复旧的完整数据库备份，也不会覆盖更新后的 Cursor 状态。

## Agent Skill

仓库包含可复用的 Skill：

```text
skills/fix-cursor-proxy-bypass/
```

安装到 Codex：

```sh
cp -R skills/fix-cursor-proxy-bypass \
  "${CODEX_HOME:-$HOME/.codex}/skills/"
```

然后调用：

```text
$fix-cursor-proxy-bypass
```

该 Skill 要求在修改前验证真实网络路径，并要求用户在修复或移除前完全退出 Cursor。

## 测试

运行基于 fixture 的测试，不会触碰真实 Cursor 数据库：

```sh
./tests/test-workaround.sh
```

## 隐私

仓库不包含 Cursor 数据库、日志、认证数据、用户专属绝对路径、本地用户名或私有代理端点。运行时备份仅保存在本地 Cursor `globalStorage` 目录中。

## 许可证

[MIT](LICENSE)
