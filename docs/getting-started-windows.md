# Windows 新电脑快速开始

本文面向“刚拿到一台新 Windows 电脑，需要恢复个人 AI 能力”的场景。

## 0. 前提

- Windows 10/11。
- Windows PowerShell 5.1 即可（系统自带）。PowerShell 7 可选，不是前置条件。
- 推荐安装 Git for Windows；没有 Git 时 doctor 仍可运行，只是无法做 Git 相关检查。

## 1. 获取公开仓库

```powershell
git clone https://github.com/SH1ROd/agent-backpack.git
cd agent-backpack
```

或者把仓库地址交给 Agent，让它按 `AGENTS.md` 的规则操作。

## 2. 只读诊断

```powershell
powershell.exe -NoProfile -File .\bootstrap\doctor.ps1
```

输出分为：

| 段落 | 含义 |
| --- | --- |
| `CurrentShell` | **运行本脚本的进程**的 PowerShell 版本、可执行文件路径、Agent 环境变量提示。 |
| `OtherInstalledShells` | `pwsh` 是否在 PATH、常见 PS7 安装位置是否存在。 |
| `Git` | Git 版本、`credential.helper`、GCM 检测、当前目录 Git 状态。 |
| `Auth` | Gitea 端点可达性（HEAD 请求）；只有在传入 `-VerifyRepositoryUrl` 时才做只读仓库验证。 |
| `Toolchain` | python / py / node / npm / ssh / ssh-keygen 是否存在（只检测，不安装）。 |
| `Tests` | 临时目录中的 UTF-8 中文路径读写、JSON 往返、`&&` 语法支持、清理结果。 |
| `Warnings` | 需要留意的异常。 |
| `Recommendations` | 建议动作，全部需要你自行决定。 |

机器可读输出：

```powershell
powershell.exe -NoProfile -File .\bootstrap\doctor.ps1 -OutputFormat Json -NoNetwork
```

> 重要：`CurrentShell` 只代表这个脚本进程。Agent 真正执行命令所用的 Shell 可能不同，必须单独确认。不要因为看到 5.1 就替 Agent 安装或切换 Shell。

## 3. 查看初始化计划

```powershell
powershell.exe -NoProfile -File .\bootstrap\windows.ps1
```

默认 `Plan` 模式，**不做任何变更**。计划项分为 `[CHANGE]`、`[MANUAL]`、`[INFO]`。

`-Apply` 只支持一个极小动作：在公开仓库之外创建私有工作目录（默认 `%USERPROFILE%\PrivateAgentAssets`），并且逐项确认。软件安装、系统配置、认证都不自动化。

```powershell
powershell.exe -NoProfile -File .\bootstrap\windows.ps1 -Apply
```

## 4. 需要私有资源时

1. 阅读 [gitea-auth.md](gitea-auth.md)。
2. 你本人在可信浏览器 / 交互终端完成认证。
3. 用一个**你确认的**私有仓库 URL 做只读验证：

   ```powershell
   powershell.exe -NoProfile -File .\providers\gitea\connect.ps1 -Method Https -VerifyRepositoryUrl "<clone URL>"
   ```

4. 需要某个仓库时，显式克隆到公开工作树之外：

   ```powershell
   powershell.exe -NoProfile -File .\providers\gitea\clone.ps1 -CloneUrl "<clone URL>" -Destination "$env:USERPROFILE\PrivateAgentAssets\<name>"
   ```

先加 `-WhatIf` 查看将要做什么：

```powershell
powershell.exe -NoProfile -File .\providers\gitea\clone.ps1 -CloneUrl "<clone URL>" -Destination "$env:USERPROFILE\PrivateAgentAssets\<name>" -WhatIf
```

## 5. 离线自检

```powershell
powershell.exe -NoProfile -File .\tests\smoke.ps1
```

不需要任何凭据。它会验证脚本语法、PS 5.1 编码、doctor JSON、中文/空格路径、危险模式与秘密模式扫描、克隆越界防护。

## 6. 执行策略说明

如果脚本被阻止运行，先阅读错误信息，**不要**全局关闭安全措施。确认脚本内容可信后，可以由你自行决定是否仅在当前进程临时放宽：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap\doctor.ps1
```

`-ExecutionPolicy Bypass` 只作用于本次进程，不修改系统设置。不要使用 `Set-ExecutionPolicy` 永久降级。

## 7. PowerShell 7 说明

- 本仓库脚本以 PS 5.1 为最低要求，不依赖 PS7-only 语法。
- 看到“手动终端里 `pwsh` 不存在”不代表系统没有 PS7，也不代表 Agent 没用 PS7。
- 如确需安装 PS7，仅从 Microsoft 官方渠道获取，并注意 MSI 与 MSIX/WindowsApps 的差异。不要由 Agent 自动安装。
- 不同安装方式与 Agent（Claude Code / Codex）的 shell 选择见 [PowerShell 7 与 Agent Shell](powershell-7.md)。

## 8. 新电脑检查清单

- [ ] `doctor.ps1` 能运行，`Tests.AllPassed = true`。
- [ ] 明确知道 Agent 实际使用的 Shell。
- [ ] 未认证时只能使用公开功能，这是预期结果。
- [ ] 认证只发生在可信界面，聊天里没有出现任何秘密。
- [ ] 私有仓库位于公开工作树之外。
- [ ] 克隆后没有自动执行任何脚本。

下一步：[Gitea 认证](gitea-auth.md) · [安全边界](security.md) · [故障排查](troubleshooting.md)
