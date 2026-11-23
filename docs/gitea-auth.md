# Gitea 认证指南

## 1. 先区分三件事

| 层面 | 证明什么 | 是否自动影响其他层面 |
| --- | --- | --- |
| Gitea Web 登录 | 浏览器会话已认证 | 否 |
| Git 传输认证（HTTPS / SSH） | 这台电脑有权 fetch/push 仓库 | 否 |
| Gitea API 认证 | 可以调用 API（如列仓库） | 否 |

浏览器能登录，不代表 `git clone` 自动成功；`git clone` 成功，也不代表 API 有权限。V1 不以 API 枚举作为第一步。

## 2. HTTPS 路径（首选）

适用于：外部网络只开放 Gitea 的 HTTPS 端口、不想管理 SSH 密钥。

### 推荐流程

1. **不要**把用户名、密码或 Token 写进 URL，也不要粘贴到聊天窗口。
2. 打开一个你自己控制的交互终端（不是 AI 聊天框）。
3. 从 Gitea 网页复制**一个具体私有仓库**的 HTTPS clone URL。
4. 在该终端执行：

   ```powershell
   git ls-remote --heads "<你的私有 clone URL>"
   ```

   如果凭据助手（Git Credential Manager 等）弹出窗口，在那里输入凭据。凭据应保存在操作系统凭据存储中。

5. 回到本仓库做只读验证：

   ```powershell
   powershell.exe -NoProfile -File .\providers\gitea\connect.ps1 -Method Https -VerifyRepositoryUrl "<同一个 clone URL>"
   ```

   脚本以 `GIT_TERMINAL_PROMPT=0`、`GCM_INTERACTIVE=Never` 运行 `git ls-remote`，不会挂起等待输入，也不会显示秘密。

### 凭据助手

- 检查：`git config --get credential.helper`
- 常见值为 `manager`（Git Credential Manager）。自建 Gitea 通常走 generic/basic 流程，具体行为需在你的 Gitea 版本上实际验证。
- 如果值为 `store`：凭据会以明文写入本地文件，不建议用于私人 Gitea。请在可信交互终端改用系统凭据管理器（例如 `manager`）；Agent 不得代改全局配置。
- 如果助手未配置，`doctor.ps1` 会报告。配置动作由你在交互终端完成，Agent 不代劳。

### Token 使用原则

- 仅在确实需要 API 时使用 Token，且只申请必要范围（例如只读仓库元数据）。
- Token 由你创建、保存在受保护位置；**不要**作为命令行参数传给脚本，本仓库脚本也不接受 Token 参数。
- 不要把 Token 写进 remote URL、脚本、`.env` 后提交到公开仓库。
- Token 失效或被撤销后，重新认证即可；不要重试风暴。

## 3. SSH 路径（可选，长期个人电脑推荐）

适用于：你愿意维护每台设备独立的密钥，并且 Gitea 确实开放了 SSH。

### 关键事实

- **SSH 端口和 clone URL 必须从 Gitea 页面的 “SSH Clone” 按钮或管理员配置获取，不能从 HTTPS 的 18443 端口猜测。**
- 首次连接必须在交互终端核验服务器主机密钥指纹。
- 每台设备使用独立密钥，丢失时可单独撤销。

### 流程

1. 在交互终端生成专用密钥（命令示例，由你执行）：

   ```powershell
   ssh-keygen -t ed25519 -C "agent-backpack@<机器名>" -f "$env:USERPROFILE\.ssh\agent-backpack_ed25519"
   ```

2. 把**公钥**添加到 Gitea：Settings → SSH / GPG Keys。

   ```powershell
   Get-Content "$env:USERPROFILE\.ssh\agent-backpack_ed25519.pub"
   ```

   公钥可以显示；**私钥绝不能显示、复制或上传**。

3. 在交互终端首次连接并核对指纹（使用 Gitea 页面给出的真实地址/端口）：

   ```powershell
   ssh -T <git-user>@<host> -p <真实 SSH 端口>
   ```

4. 只读验证：

   ```powershell
   powershell.exe -NoProfile -File .\providers\gitea\connect.ps1 -Method Ssh -VerifyRepositoryUrl "<ssh clone URL>"
   ```

   脚本使用 `ssh -o BatchMode=yes`，不会自动接受未知主机密钥，也不会生成密钥。

## 4. 错误与预期行为

| 现象 | 含义 | 处理 |
| --- | --- | --- |
| `AuthRequiredOrFailed` | HTTPS 凭据缺失/失效，或 SSH 密钥未被授权 | 在交互终端重新认证 |
| `TlsFailure` | 证书链/主机名问题 | 检查服务器证书；不要关闭 TLS 校验 |
| `HostKeyFailure` | SSH 主机密钥未知或变化 | 交互式连接并核验指纹；变化时警惕中间人 |
| `DnsFailure` / `NetworkFailure` | 网络或 DNS 不可达 | 检查网络；不要修改 hosts/防火墙绕过 |
| `HttpError 401/403` | 端点可达但未授权 | 属于认证问题，不是网络问题 |
| `Timeout` | 超时 | 检查连接；脚本已设置超时，不会无限等待 |

## 5. 私有清单仓库

计划中的 `agent-backpack-private` 是**可选**的私有索引仓库：

- 不存在时，不代表认证失败。
- V1 不会因为找不到它而报错。
- 你可以先用任意一个已有私有仓库做只读验证。

## 6. 撤销与轮换

- 设备丢失：撤销该设备的 SSH 公钥 / Token，必要时轮换已下载的明文密钥。
- 撤销远端权限**不会**删除本地已克隆的副本，需要你自行清理。
- 历史中已提交的秘密不会因为删除最新文件而消失；如发生未授权读取，按影响范围更换密钥。

## 7. 代理与 PATH 说明

脚本通过 `ProcessStartInfo` 直接调用 `git`，因此会继承当前进程环境（包括 HTTP(S)_PROXY）。如果 Git 在交互终端可用而在 Agent 中不可用，先对比两边的环境变量，而不是修改全局配置。
