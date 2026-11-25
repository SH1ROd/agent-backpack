# PowerShell 7 与 Agent Shell

本仓库脚本以 **Windows PowerShell 5.1** 为最低要求，不依赖 PowerShell 7 专属语法。PowerShell 7 是可选增强，本文说明安装方式以及不同 Agent 实际使用哪个 shell。

## 安装方式

| 方式 | 典型位置 | 是否需要管理员 | `pwsh` 是否在 PATH |
| --- | --- | --- | --- |
| winget / MSIX（按用户） | `%LOCALAPPDATA%\Microsoft\WindowsApps\` | 否 | 是（WindowsApps 别名） |
| 官方 ZIP 解压 | 自定义目录，例如 `C:\Program Files\PowerShell\7` | 写入 Program Files 时需要 | 否，需自行加入 PATH |
| 官方 MSI（机器级） | `C:\Program Files\PowerShell\7` | 是 | 通常由安装器加入 |

仅从 Microsoft 官方渠道获取安装包，并核对 SHA256。不要由 Agent 自动安装。

## Claude Code 的 PowerShell 工具

Claude Code 的 PowerShell 工具**不查 PATH**，按固定顺序检查：

1. `C:\Program Files\PowerShell\7\pwsh.exe`
2. `C:\Program Files\PowerShell\7-preview\pwsh.exe`
3. `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`

因此：

- 只装 winget/MSIX 版（位于 `%LOCALAPPDATA%\Microsoft\WindowsApps`）时，Claude Code 找不到它，会回落到 5.1。
- 想让 Claude Code 使用 7.x，需要让 `C:\Program Files\PowerShell\7\pwsh.exe` 存在：安装机器级 MSI，或把官方 ZIP 解压到该目录。
- `CLAUDE_CODE_SHELL` 用于 Bash/POSIX shell，不适用于 PowerShell 工具。
- 不需要修改 `PATH`、`ComSpec`、`SHELL` 等环境变量来影响这个选择。

> 结论：交互终端可以是 PowerShell 7，而 Claude Code 的 PowerShell 工具仍可能是 5.1；两者是独立选择。

## VS Code

- 可以在 `settings.json` 中把 `terminal.integrated.defaultProfile.windows` 设为 `PowerShell`。
- 建议显式指定 `pwsh.exe` 的路径，避免 VS Code 探测到旧版本。
- 安装或切换 PowerShell 后执行一次 `Developer: Reload Window`。
- Claude Session Restore 等扩展恢复的终端使用 VS Code 的默认终端 profile。

## Codex 及其他 Agent

- Agent 的命令执行 shell 可能与手动终端不同；以 `bootstrap/doctor.ps1` 的 `CurrentShell` 报告为准。
- Codex 是否使用 `pwsh` 取决于版本和配置；不要假设，也不要为了兼容修改全局环境变量。
- 如果 Agent 提供 shell 配置项，优先使用项目级或 Agent 级配置，并记录实际生效的路径。
- 如果 Agent 自带 PowerShell 运行时，不要据此推断系统 PATH 中的 `pwsh` 情况。

## 与 5.1 的关系

- PowerShell 7 是 5.1 的现代替代，但 5.1 是 Windows 组件，不能卸载。
- 本仓库脚本保持 5.1 兼容；在 7.x 下运行通常也可以，但不要引入仅 7.x 可用的语法。
- 某些 Windows 专用模块仍可能要求 5.1。
