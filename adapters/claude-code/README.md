# Claude Code Adapter

Claude Code 会读取仓库根目录的 [`CLAUDE.md`](../../CLAUDE.md)，后者指向 [`AGENTS.md`](../../AGENTS.md)。

## 建议的启动方式

```text
Read CLAUDE.md and AGENTS.md. Start with read-only diagnostics
(bootstrap/doctor.ps1). Do not access private Gitea or change the machine
without my explicit approval. Never ask me to paste secrets into chat.
```

## 注意

- `CLAUDE.md` 只保留 Claude Code 的简短入口，完整规则统一维护在 `AGENTS.md`，避免两套规范冲突。
- 不修改用户的全局 Claude 配置来达成项目兼容；项目级文件优先。
- 涉及认证时，引导用户在可信终端完成；Claude Code 不应接收或转述任何秘密。
- 克隆私有仓库前确认目标位于公开工作树之外。
