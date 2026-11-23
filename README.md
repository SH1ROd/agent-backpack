# Agent Backpack

> Your portable AI agent toolkit. Build once, carry everywhere.

中文名：**AI 智能体背包** —— 面向 Windows 的个人 AI 能力与环境恢复入口。

Agent Backpack 是一个**公开引导层 + 私有能力索引 + 适配执行层**的项目。它本身不保存任何私人凭据，而是帮助你在新电脑上：

1. 由 Agent 读取公开说明，完成只读环境诊断；
2. 由你亲自在可信的交互界面完成 Gitea 认证；
3. 按需、经你明确授权后，恢复私人 Git 仓库、Skills、MCP、CLI 与配置；
4. 全程不把密码、Token、Cookie 或 SSH 私钥交给聊天窗口。

> **公开仓库不是访问私人资源的凭据。** 任何人拿到本仓库地址，也只能获得公开文档与脚本；私人资源由私人 Gitea / NAS 的服务端权限控制。

---

## 快速开始（人类）

要求：Windows 10/11，自带 Windows PowerShell 5.1 即可；Git 为可选但推荐。

```powershell
git clone https://github.com/SH1ROd/agent-backpack.git
cd agent-backpack

# 只读环境诊断（不会修改系统）
powershell.exe -NoProfile -File .\bootstrap\doctor.ps1

# 查看初始化计划（默认 Plan，不做任何变更）
powershell.exe -NoProfile -File .\bootstrap\windows.ps1

# 离线自检
powershell.exe -NoProfile -File .\tests\smoke.ps1
```

机器可读诊断：

```powershell
powershell.exe -NoProfile -File .\bootstrap\doctor.ps1 -OutputFormat Json -NoNetwork
```

---

## 把仓库交给 Agent（一句话）

在任意具备命令执行能力的 Agent（Codex、Claude Code、DSh 等）中发送：

```text
Read AGENTS.md and docs/getting-started-windows.md from this repository.
Start with read-only environment diagnostics and explain a plan.
Do not access private Gitea or modify the machine until I explicitly approve.
If private resources are needed, guide me through authentication in a
trusted interactive interface; never ask me to paste secrets into chat.
```

预期行为：先 `plan` / `doctor`，列出缺失工具与拟变更项，等待你确认；需要私人资源时，引导你本人在浏览器或独立终端完成认证。

---

## 目录结构

```text
agent-backpack/
├── README.md
├── AGENTS.md                     # 跨 Agent 入口与操作规则
├── CLAUDE.md                     # Claude Code 兼容入口（指向 AGENTS.md）
├── .gitignore
├── bootstrap/
│   ├── doctor.ps1                # 只读环境诊断（PS 5.1 兼容）
│   └── windows.ps1               # 用户确认式初始化（默认仅计划）
├── providers/
│   └── gitea/
│       ├── connect.ps1           # 认证引导 + 只读连通性验证
│       ├── discover.ps1          # API 元数据发现（V1 未实现，显式返回）
│       └── clone.ps1             # 用户确认的单仓只读克隆
├── manifests/
│   ├── sources.yaml              # 公开接入元信息（无秘密）
│   ├── capabilities.example.yaml # 通用能力定义示例（无私人仓库名）
│   └── schema.md                 # 字段、版本与安全规则
├── adapters/
│   ├── codex/README.md
│   ├── claude-code/README.md
│   └── generic/README.md         # DSh 等未知 Agent 遵循通用入口
├── docs/
│   ├── getting-started-windows.md
│   ├── gitea-auth.md
│   ├── private-resources.md
│   ├── security.md
│   └── troubleshooting.md
├── tests/
│   ├── smoke.ps1                 # 离线 smoke test
│   └── fixtures/                 # 仅伪数据
└── tools/
    └── vscode-claude-session-restore/  # 多会话自动恢复 VS Code 扩展
```

---

## 能力现状（V1 / P0）

| 模块 | 状态 |
| --- | --- |
| `doctor.ps1` 只读诊断、JSON 输出、沙箱自检 | 已实现 |
| `windows.ps1` 初始化计划 / 受限 Apply | 已实现（默认 Plan） |
| Gitea HTTPS 认证引导与只读 `git ls-remote` 验证 | 已实现（需用户提供仓库 URL） |
| Gitea SSH 认证引导 | 已实现（引导，不自动生成密钥） |
| 单个私有仓库克隆（显式授权） | 已实现 |
| Gitea API 元数据发现 | 未实现（返回 `NotImplemented`） |
| 私有能力安装 / 验证 | 未实现（仅定义 schema） |
| NAS 大型资产下载 | 未实现（仅预留描述） |

未实现的模块会明确报告“未实现 / 需要授权”，不会静默成功。

---

## 辅助工具：多会话自动恢复

[`tools/vscode-claude-session-restore/`](tools/vscode-claude-session-restore/README.md) 是一个可打包的 VS Code 扩展：

- 定期和关闭前调用 `claude agents --json`，自动发现当前工作区的活动 Claude Code 会话；
- 下次打开工作区时，为每个会话创建终端并执行 `claude --resume <sessionId>`；
- 不需要为每个 session 手工维护命令；`/rename` 不影响恢复，`/branch` 产生的新会话会以新 ID 自动纳入快照；
- 默认只在受信任工作区启用，自动恢复的额外参数（例如 `--dangerously-skip-permissions`）需要你在设置中显式配置。

它属于本仓库的可选工具，不影响 `doctor.ps1` / bootstrap 的安全边界。

---

## 认证与安全边界

- 登录 Gitea 网页 ≠ Git 传输已认证 ≠ Gitea API 已认证，三者相互独立。
- 私人仓库访问必须由你本人完成认证；Agent 只检查成功/失败，不读取、不回显秘密。
- 私有仓库默认克隆到公开工作树**之外**的受控目录（如 `%USERPROFILE%\PrivateAgentAssets`），绝不进入本仓库。
- 克隆后不会自动执行仓库内的脚本、post-install 或 npm 脚本。
- 认证失败时不会关闭 TLS 校验、不会跳过 SSH 主机密钥检查、不会降级为明文凭据。

详细说明见 [docs/security.md](docs/security.md)、[docs/gitea-auth.md](docs/gitea-auth.md)。

---

## 平台

- 首选 Windows 10/11，最低 Windows PowerShell 5.1。
- PowerShell 7 推荐但不是前置条件；检测到 `pwsh` 仅作报告，不自动安装。
- 脚本不修改系统全局设置、注册表、环境变量、防火墙或执行策略。

---

## 开发与测试

```powershell
powershell.exe -NoProfile -File .\tests\smoke.ps1
```

`tests/smoke.ps1` 执行：脚本语法解析、PS 5.1 编码检查、doctor JSON 校验、中文/空格路径读写、危险模式扫描、秘密模式扫描、单仓克隆越界防护测试。全部离线，不需要任何凭据。

---

## 许可证

许可证尚未确定（TODO）。在添加许可证之前，本项目不授予复制、修改或再分发授权。你可以在审核后自行选择许可证。

---

## 免责声明

本项目是个人环境恢复工具，按“现状”提供。使用前请自行审阅脚本；不要在不受信任的环境中执行来源不明的二次修改版本。
