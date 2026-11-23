# Claude Session Restore（VS Code 扩展）

自动快照当前工作区的 Claude Code 活动会话，并在 VS Code 重新打开这个工作区时，为每个会话开一个终端并执行：

```powershell
claude --resume <sessionId>
```

适合“一个项目一个 VS Code 窗口、同时开多个 Claude session”的工作流。

## 它解决什么问题

VS Code 关闭时，普通终端里的 Claude 进程会结束。Claude Code 的会话虽然保存在磁盘上，但下次要手动 `claude --resume`，而且多个会话很难逐个找回。

这个扩展：

1. 定期以及窗口关闭前调用 `claude agents --json`，找出当前项目里**活动的** Claude 会话。
2. 把 `sessionId`、显示名、kind/status 保存到工作区存储（不是仓库）。
3. 下次打开同一工作区时，为每个快照会话创建终端并 `claude --resume <sessionId>`。
4. 已经在其他进程/窗口运行的会话会跳过，避免两个进程写同一个 transcript。
5. 窗口 Reload 后 VS Code 可能保留旧终端标签；扩展会按终端名去重：活动会话保留最新一个终端，非活动会话清掉旧标签再恢复，避免出现两组同名终端。

`sessionId` 是稳定标识；`/rename` 只改显示名，不影响恢复。`/branch` 新产生的会话会以新 ID 出现在快照里。

## 安装

### 从源码打包（推荐）

```powershell
cd tools\vscode-claude-session-restore
npx --yes @vscode/vsce package --skip-license
code --install-extension .\claude-session-restore-0.1.0.vsix
```

安装后在 VS Code 里执行 `Developer: Reload Window`，或重新打开窗口。

> **自定义扩展目录（`VSCODE_EXTENSIONS`）**：如果你迁移过 VS Code 扩展目录，`code --install-extension` 可能装到默认目录而不是当前窗口使用的目录。请改用：
>
> ```powershell
> code --extensions-dir "$env:VSCODE_EXTENSIONS" --install-extension .\claude-session-restore-0.1.0.vsix
> ```
>
> 或在当前窗口的扩展视图里使用 “Install from VSIX...”。

> **VS Code 1.97+ 发布者信任提示**：通过 `--install-extension` 或 VSIX 安装的扩展，发布者不会自动被信任。如果没有看到本扩展激活，请打开扩展视图搜索 “Claude Session Restore”，点击 **Trust Publisher**；或在命令面板运行 **Extensions: Manage Trusted Extensions Publishers**，把 `SH1ROd` 加入信任列表，然后再次 Reload Window。否则扩展会显示为已安装但不会激活。

### 开发模式

在 VS Code 中打开本目录，按 `F5` 启动 Extension Development Host。

## 使用

第一次安装后：

1. 打开一个项目，正常启动 Claude Code（`claude` 或你的启动方式）。
2. 保持窗口运行至少一个快照周期（默认 30 秒），或执行命令面板：
   `Claude Sessions: Snapshot Active Sessions Now`
3. 关闭 VS Code。扩展在 `deactivate` 时还会做一次同步快照。
4. 重新打开该项目，扩展会自动为快照中的每个会话创建终端并 resume。

命令面板还有：

- `Claude Sessions: Restore Snapshot Now` — 立即手动恢复
- `Claude Sessions: Clear This Workspace Snapshot` — 清空当前工作区快照

## 测试

```powershell
node test/core.test.js
node test/extension.test.js
```

`extension.test.js` 使用 mock 的 VS Code API 验证激活/快照/恢复流程；它会真实执行 `claude agents --json` 查询当前活动会话，但不会启动或恢复真实 Claude 进程。

## 设置

| 设置 | 默认 | 说明 |
|---|---|---|
| `claudeSessionRestore.enabled` | `true` | 总开关 |
| `claudeSessionRestore.autoRestore` | `true` | 打开工作区时自动恢复 |
| `claudeSessionRestore.allowUntrustedWorkspaces` | `false` | 是否允许在未信任工作区自动恢复 |
| `claudeSessionRestore.snapshotIntervalSeconds` | `30` | 快照周期；0 关闭定时器 |
| `claudeSessionRestore.maxSessions` | `8` | 每个工作区最多快照/恢复多少个会话 |
| `claudeSessionRestore.revealTerminals` | `true` | 是否显示第一个恢复的终端 |
| `claudeSessionRestore.claudeCommand` | `claude` | 终端里执行的命令；可填绝对路径 |
| `claudeSessionRestore.extraArgs` | `[]` | 追加到 resume 命令的参数，例如 `["--dangerously-skip-permissions"]` |
| `claudeSessionRestore.clearSnapshotWhenNoSessions` | `true` | 查询成功但没有活动会话时清空快照 |

## 安全注意事项

- 自动恢复会在你打开工作区时启动 Claude Code。若 `extraArgs` 包含 `--dangerously-skip-permissions`，相当于**自动以绕过权限模式启动**。只建议在受信任项目使用。
- 扩展默认不在未信任工作区自动恢复。
- 快照只包含 session ID、显示名、kind/status、cwd，不包含对话内容或凭据；保存在 VS Code 的扩展工作区存储中。
- 同一个 session 不要同时在两个窗口恢复，否则消息可能交错。扩展会跳过当前已经活动的 session。
- 快照文件位于 VS Code 工作区存储，不在本仓库，也不会被 git 跟踪。

## 已知限制

- 需要 Claude Code CLI 支持 `claude agents --json`（本机验证版本 2.1.300）。
- 多根工作区只处理第一个文件夹（与 Claude Code 自身的工作区绑定行为一致）。
- 如果 VS Code 崩溃（没有执行 `deactivate`），只能依赖最近一次定时快照；最多可能丢失一个快照周期内的变化。
- 会话被删除、移动项目目录、或使用了 `--fork-session` 生成新 ID 时，旧 ID 可能恢复失败；重新快照即可。
- 扩展只记录 `sessionId`，不记录每个会话启动时的原始 CLI 参数；`extraArgs` 对所有恢复的会话统一生效。
- 自动恢复的终端使用 VS Code 的默认终端 profile。建议把默认 profile 设为 PowerShell 7。

## 在其他 PC 上复用

把整个 `tools/vscode-claude-session-restore` 目录带到其他 PC，或从 agent-backpack 仓库获取，然后：

```powershell
npx --yes @vscode/vsce package --skip-license
code --install-extension .\claude-session-restore-0.1.0.vsix
```

要求目标 PC 已安装 Claude Code CLI，并且 `claude agents --json` 可用。快照是每台机器/每个工作区独立的，不会跨机器同步。

## 许可证

本扩展属于 agent-backpack 项目；项目的许可证仍待所有者决定。在添加许可证之前，请勿假定可以再分发。
