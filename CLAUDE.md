# CLAUDE.md

> Claude Code 兼容入口。完整规则见 [AGENTS.md](AGENTS.md)；本文件不重复规则，冲突时以 AGENTS.md 为准。

- 先阅读 `AGENTS.md`、`README.md`、`docs/security.md`，再执行任何命令。
- 默认只读：先运行 `bootstrap/doctor.ps1`，向用户说明计划，等待批准后再变更。
- 不要索取或回显密码、Token、Cookie、SSH 私钥；认证由用户在可信交互终端完成。
- 认证通过前不访问私人 Gitea；克隆仅限用户明确指定的单个仓库，且目标在公开工作树之外。
- 本仓库最低运行环境是 Windows PowerShell 5.1；脚本改动后运行 `tests/smoke.ps1`。
- 未经用户逐项批准，不执行 `git commit` / `git push` / 远端写操作。

常用命令：

```powershell
powershell.exe -NoProfile -File .\bootstrap\doctor.ps1
powershell.exe -NoProfile -File .\bootstrap\windows.ps1
powershell.exe -NoProfile -File .\tests\smoke.ps1
```
