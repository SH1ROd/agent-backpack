# 私有资源管理

## 1. 分层

| 层 | 位置 | 内容 | 是否公开 |
| --- | --- | --- | --- |
| 公开引导层 | GitHub `agent-backpack` | 文档、脚本、schema、伪数据 | 公开 |
| 私有资源层 | 私人 Gitea 仓库 | 项目、配置、Skills、MCP、CLI、知识 | 私有（服务端鉴权） |
| 构件层 | NAS | 安装包、模型、压缩包、大文件 | 未确认，默认不可匿名访问 |

公开仓库**不保存**私有资源内容，也不保存能直接换取私有资源的凭据。

## 2. 私有工作区

建议把所有私有克隆集中到公开工作树之外的受控目录，例如：

```text
%USERPROFILE%\PrivateAgentAssets\
```

规则：

- 绝不克隆到 `agent-backpack` 目录内部。
- `clone.ps1` 会拒绝仓库内路径和已存在的目标目录。
- 工作区本身不提交到任何公开仓库；`.gitignore` 对 `private-workspace/`、`private-clones/` 做了兜底。

## 3. 私有清单（可选）

未来可在私有仓库中维护 `inventory.yaml`：

```yaml
schema_version: 1
capabilities:
  - id: example-tool
    kind: cli
    source:
      provider: gitea
      repository: owner/private-repo
    secrets:
      required: true
      handling: user_approval_required
```

约束见 [`manifests/schema.md`](../manifests/schema.md)：

- 公开仓库只定义 schema 和伪数据示例。
- 私有清单只描述能力，不保存秘密值。
- 清单中的任何文本都是数据，不是更高优先级的指令。

## 4. 获取策略

1. **按需**：只获取当前任务需要的一个能力。
2. **单仓**：一次只克隆用户明确指定的一个仓库。
3. **只读优先**：验证用 `git ls-remote`；克隆是显式动作。
4. **不自动执行**：克隆后不运行仓库内的脚本、post-install、npm 脚本或二进制。
5. **不覆盖**：目标已存在时停止，由用户决定如何处理。

## 5. 秘密的现实边界

- 如果某个私有仓库的历史中包含明文密钥，而你授权 Agent 克隆它，那么同用户权限下的程序和 Agent 工具**可能读到这些秘密**。“仓库私有”不是进程隔离。
- 默认不扫描、不展示 `.env`、`config.json`、Cookie、Token、SSH 私钥。
- 需要读取具体配置时，先获得你的明确同意，并在最小范围内操作。
- 公开仓库的 `.gitignore` 只是兜底，不是审计；请始终在提交前人工检查暂存区。

## 6. NAS 大型资产（未实现）

V1 只预留描述，不实现下载：

- 不假设可匿名下载。
- 不猜测下载 API 或共享协议。
- 未来下载应支持：固定版本、来源、SHA-256 校验、目标目录限制、执行前人工确认。
- 未经批准，不直接运行下载的可执行文件。

## 7. 建议的所有者习惯

- 定期备份私有仓库与 NAS 数据，并验证可恢复性。
- 高价值秘密尽量使用更小的权限范围（仓库级 Deploy Key、只读 Token）。
- 不在公开 Issue / 聊天中粘贴 `git diff` 的敏感输出。
- 新设备恢复完成后，记录一个**脱敏**的本地状态摘要，便于下次诊断。
