# 故障排查

## PowerShell 5.1

### 中文乱码 / 脚本解析异常

- 含非 ASCII 字符的 `.ps1` 应以 **UTF-8 with BOM** 保存。Windows PowerShell 5.1 对无 BOM 的 UTF-8 脚本可能按 ANSI 解析。
- 用 `tests/smoke.ps1` 可以检查：非 ASCII 的 `.ps1` 是否带 BOM。
- 读取数据文件时显式指定编码：

  ```powershell
  Get-Content -LiteralPath .\file.txt -Encoding UTF8 -Raw
  ```

### `pwsh is not recognized`

- 只说明当前进程的 PATH 中没有 PowerShell 7。
- 不代表系统没装，也不代表 Agent 用的是 5.1。
- 本仓库脚本不需要 `pwsh`；不要为此自动安装。
- 如果 Claude Code 的 PowerShell 工具仍显示 5.1，这不是 PATH 问题：Claude Code 只检查固定路径，详见 [PowerShell 7 与 Agent Shell](powershell-7.md)。

### 语法错误：`&&` / 三元运算符 / `??`

这些是 PowerShell 7 语法。本仓库要求 PS 5.1 兼容，请改写为 `if/else` 或分步命令。`doctor.ps1` 会报告当前 Shell 是否支持 `&&`。

### 执行策略阻止脚本

先阅读错误。确认脚本可信后，可以仅对当前进程放宽：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap\doctor.ps1
```

不要永久执行 `Set-ExecutionPolicy Unrestricted`。Agent 不得静默修改执行策略。

### `ConvertFrom-Json` 结果类型不符合预期

Windows PowerShell 5.1 的 `ConvertTo-Json` 有一个已知行为：单元素数组可能被序列化为单个对象。消费 JSON 时请同时兼容“对象或数组”，例如：

```powershell
@($report.Warnings).Count
```

## Git / 认证

### `Authentication failed` / 401 / 403

- Web 登录成功不等于 Git 已认证。
- 在交互终端执行一次 `git ls-remote --heads "<clone URL>"` 并完成凭据提示。
- 检查 `credential.helper`；必要时在交互终端配置 GCM。
- Agent 脚本以 `GIT_TERMINAL_PROMPT=0` 运行，不会替你输入凭据，这是有意设计。

### `SSL certificate problem` / 证书错误

- 检查系统时间、证书链、主机名是否匹配。
- 不要使用跳过证书校验的开关，也不要修改 hosts 绕过。
- 私人服务应使用可信 TLS 证书（例如 Let's Encrypt 或自有 CA 并正确分发）。

### SSH: `Host key verification failed`

1. 在交互终端用 Gitea 页面给出的真实地址与端口连接一次。
2. 核对服务器指纹后写入 `known_hosts`。
3. 若指纹与之前不同，先排查中间人或服务器更换，不要盲目删除 known_hosts 条目。

### SSH 端口连不上

- 不要假设 SSH 与 HTTPS 用同一个端口。
- 从 Gitea 页面获取 SSH clone URL 与端口；若公网未开放 SSH，改用 HTTPS。

### 克隆超时

- 检查网络与代理；脚本继承当前进程的代理环境变量。
- `clone.ps1` 默认 180 秒超时；失败时可能留下部分目录，脚本不会自动删除，请人工检查。

### 目标目录已存在

`clone.ps1` 不会覆盖或更新已有目录。请自行确认后删除或换路径。恢复已有克隆时，用 `git -C <dir> status` 查看状态，不要 force push / reset。

## Doctor 输出

### `Auth.PrivateAccess.Result` 一直是 `NotChecked`

只有传入 `-VerifyRepositoryUrl` 才会验证私有仓库。默认不访问任何私人内容，这是预期行为。

### `Auth.Network.Status = TlsFailure`

TLS 握手失败。检查证书与系统时间；不要降低安全设置。

### `Tests.AllPassed = false`

查看 `Tests` 各字段：

- `Utf8ChinesePathWriteRead`：临时目录中文/空格路径读写；
- `JsonRoundTrip`：JSON 序列化往返；
- `TempCleanupSucceeded`：临时目录清理。

若清理失败，脚本会保留路径供人工检查。确认无用后手动删除。

### JSON 中出现 `%USERPROFILE%`

这是脱敏结果，属正常现象。

## 发布前检查

```powershell
git status --short
git add .
git diff --cached --stat
git diff --cached --name-only
git diff --cached
```

- 确认没有任务书、私有工作区、Token、`.env`、私钥。
- 不要把 `git diff --cached` 的敏感输出贴到公开聊天或 Issue。
- 不要把设计任务书原文放入公开仓库。

## 常见 Git 报错

| 错误 | 处理 |
| --- | --- |
| `fatal: not a git repository` | 进入正确目录，必要时 `git init`。 |
| `remote origin already exists` | `git remote -v` 核对，不要盲改。 |
| `src refspec main does not match any` | 确认已有提交，再重命名/切换分支。 |
| `rejected (fetch first)` | 远端不是空仓库；先检查，**不要 force push**。 |
| `Authentication failed` | 使用 Git/GCM 的交互认证，不在 URL 写密码。 |
