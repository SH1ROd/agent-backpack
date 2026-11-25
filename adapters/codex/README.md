# Codex Adapter

Codex 及其他 OpenAI 风格 Agent 请以仓库根目录的 [`AGENTS.md`](../../AGENTS.md) 为首要入口。

## 建议的启动方式

```text
Read AGENTS.md, README.md and docs/security.md from this repository.
Run bootstrap/doctor.ps1 read-only. Explain a plan. Do not install software,
access private Gitea, or modify the machine until I explicitly approve.
```

## 注意

- 是否自动读取 `AGENTS.md` 取决于你使用的 Codex 版本与配置；如果没有自动读取，请在首条消息中明确要求。
- Codex 的实际命令执行 Shell 可能与你手动打开的终端不同。以 `doctor.ps1` 的 `CurrentShell` 报告为准，但仍需单独确认 Agent Shell。
- 不要为了“兼容”而修改你所有项目的全局 Agent 配置；先使用项目级入口。
- 如果 Codex 自带 PowerShell 7 运行时，不要据此推断系统 PATH 中的 `pwsh` 情况。
- Codex 是否使用 PowerShell 7 取决于版本与配置；不要假设，也不要为此修改全局环境变量。详见 [PowerShell 7 与 Agent Shell](../../docs/powershell-7.md)。
