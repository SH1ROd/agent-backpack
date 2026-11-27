# Oink 双 Windows 协同适配指南

> 面向 Windows 10/11 新环境的快速部署、共存配置、排查与验收参考。

## 1. 定位与选型边界

- **用途**：两台 Windows 电脑之间的局域网低延迟键鼠共享、剪贴板同步与文件拖拽（软件 KVM）。
- **官方项目**：[oinkvm/oink](https://github.com/oinkvm/oink) · [Releases](https://github.com/oinkvm/oink/releases) · [Issues](https://github.com/oinkvm/oink/issues)
- **已验证稳定版基线**：`v0.3.7`（`Oink-0.3.7-windows-x64.msi`，Windows 10 1809+ / Windows 11 x64；实际部署前先核对官方最新稳定版）。
- **边界原则**：
  - 仅用于 Windows ↔ Windows 协同；已有手机协同（如小米电脑管家）保持原有拓扑，不重复引入重叠组件。
  - 不同时开启多个软件 KVM（PowerToys MWB、MWB 独立版、Deskflow、TwinDesk、Synergy 等）。
  - 自动解锁、虚拟音频驱动等会增加权限或改动系统的增强功能默认关闭，按需单独验证。
  - 若核心体验（P0）不达标，回退到原始状态后再评估 MWB 独立版、PowerToys MWB 或 Deskflow。

---

## 2. 新机只读盘点

安装前先在目标机器执行只读检查，确认系统架构、冲突 KVM、现有剪贴板/协同工具、网络配置与显示器状态：

```powershell
# 系统版本与架构
Get-CimInstance Win32_OperatingSystem |
  Select-Object Caption, Version, BuildNumber, OSArchitecture

# 冲突软件与已有协同工具进程 / 服务
Get-Process |
  Where-Object { $_.ProcessName -match 'oink|powertoys|mousewithoutborders|deskflow|twindesk|synergy|xiaomi' } |
  Select-Object ProcessName, Id

Get-Service |
  Where-Object { $_.Name -match 'oink|mousewithoutborders|deskflow|twindesk|xiaomi' -or $_.DisplayName -match 'oink|mouse without borders|deskflow|xiaomi' } |
  Select-Object Name, DisplayName, Status

# 网络配置文件与虚拟网卡（排查局域网发现干扰）
Get-NetConnectionProfile | Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity
Get-NetAdapter | Select-Object Name, Status, LinkSpeed

# 显示器信息（DPI 与实际排布需在 Windows 显示设置中核实）
Get-CimInstance Win32_VideoController |
  Select-Object Name, CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate
```

---

## 3. 官方获取、校验与安装

仅从官方 GitHub Releases 获取安装包，校验 SHA-256 与数字签名后再安装；**不要**为安装关闭 Defender、防火墙或 UAC。

```powershell
# 1. 查询最新稳定版元数据与官方摘要
$rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/oinkvm/oink/releases/latest' `
  -Headers @{ 'User-Agent' = 'agent-backpack' }
$rel.tag_name
$rel.assets | Where-Object { $_.name -like '*windows-x64.msi' } | Select-Object name, digest, browser_download_url

# 2. 下载后校验 SHA-256 与签名（以 v0.3.7 为例，新版请替换为官方摘要）
# 注：v0.3.7 官方 MSI 未做 Authenticode 代码签名（SigStatus: NotSigned），请务必核对官方 SHA-256。
$msi = "$env:TEMP\Oink-0.3.7-windows-x64.msi"
(Get-FileHash -Path $msi -Algorithm SHA256).Hash
Get-AuthenticodeSignature -FilePath $msi | Select-Object Status, @{N='Signer';E={$_.SignerCertificate.Subject}}

# 3. 带安装日志启动标准 MSI 安装（UAC 由用户亲自确认）
msiexec /i $msi /L*v "$env:TEMP\oink-install.log"
```

### 回滚与卸载

- 通过 Windows **设置 → 应用 → 已安装的应用** 卸载 Oink，或使用 `msiexec /x <msi或ProductCode>`。
- 卸载后按需清理用户目录下的 Oink 配置，即可恢复安装前状态。

---

## 4. 配对与渐进配置

1. **双端版本一致**：两台 Windows 安装同一正式稳定版。
2. **局域网配对**：优先确认物理网卡为 `Private`（专用网络），由用户亲自确认对端与配对码；**不要**把配对码写入笔记、聊天或日志。
3. **虚拟网卡注意**：若本机存在代理 TUN 网卡、VPN（如 Radmin VPN / Tailscale）或虚拟显示器驱动（如 OrayIddDriver），配对或跨屏异常时优先排查其干扰。
4. **渐进开启功能**：
   - 先只启用 **键鼠共享 + 文本剪贴板**，配置紧急暂停/退出快捷键并实测本机输入随时可恢复；
   - 稳定后再开启 **图片剪贴板** 与 **文件/文件夹拖拽**；
   - 音频转发、自动解锁等默认保持关闭。

---

## 5. 与小米电脑管家剪贴板共存策略

若其中一台 Windows 已通过小米电脑管家连接手机并提供共享剪贴板：

1. **先立基线**：安装/开启 Oink 前，先确认手机 ↔ 电脑原有剪贴板正常。
2. **保留去重**：优先开启 Oink 的剪贴板去重选项（`v0.3.5+` 引入，具体名称以当前界面为准）。
3. **对照验证**：用带序号的合成文本（不要用真实敏感内容）分别测试：
   - 仅小米电脑管家运行；
   - 仅 Oink 运行（Windows A ↔ B）；
   - 两者共存（快速连续复制、重复复制、多行代码、中英文）。
4. **异常处理**：出现回环、旧内容覆盖或持续触发时，先通过单工具对照定位，再调整同步方向或内容类型，不要直接全局禁用小米剪贴板来掩盖问题。

---

## 6. 常见问题排查线索

以下为上游公开 Issue / 更新线索，仅作排查方向参考，不代表本机必现：

| 现象 | 排查重点 | 参考 |
| --- | --- | --- |
| 跨屏鼠标漂移 / 乱飞 | 多屏 DPI 缩放、分辨率、物理排布、虚拟显示器驱动、长时间闲置后跨屏 | [oink#113](https://github.com/oinkvm/oink/issues/113) |
| Windows 截图粘贴失败 | 区分 `Win+Shift+S` 与第三方截图工具、首次直接粘贴、是否与小米剪贴板冲突 | [oink#107](https://github.com/oinkvm/oink/issues/107) |
| 数字小键盘异常 | 检查 NumLock 状态、物理端与远端输入差异 | [oink#122](https://github.com/oinkvm/oink/issues/122) |
| VPN / 跨网配对失败 | 检查局域网优先路由与防火墙规则；仅实际走 VPN 时再查 MTU，不预先修改系统 MTU | [oink#117](https://github.com/oinkvm/oink/issues/117) |
| 启动 / 升级异常 | 查看 MSI 安装日志、后台服务与残留进程 | [v0.3.7 Release](https://github.com/oinkvm/oink/releases/tag/v0.3.7) |

---

## 7. 新机验收清单（精简版）

逐项标记 `PASS / FAIL / BLOCKED / N/A`，P0 全部通过才建议作为日常主力：

| 编号 | 优先级 | 项目 | 通过标准 |
| --- | --- | --- | --- |
| T01 | P0 | A↔B 双向键鼠 | 连续往返 30 次以上，无乱飞、卡死、按键残留或本机输入丢失 |
| T02 | P0 | 输入法与快捷键 | 中文输入法、中英切换、IDE 快捷键、组合键正常；有小键盘测 NumLock |
| T03 | P0 | Windows 文本剪贴板 | 双向复制普通文本、多行代码及快速连续复制无旧内容覆盖 |
| T04 | P0 | 手机协同共存 | 小米电脑管家原有手机连接与剪贴板保持正常，无回环/重复写入 |
| T05 | P0 | 恢复与重连 | 重启/登录、休眠唤醒及短时断网后自动恢复，无需重复配对 |
| T06 | P0 | 常用软件兼容 | IDE、终端、浏览器、资源管理器正常；异常时用开关对照定位 |
| T07 | P0 | 紧急恢复与回滚 | 任一端可随时暂停并恢复本机输入；可按第 3 节干净卸载 |
| T08 | P1 | 图片剪贴板 | 双向截图及图片粘贴，单独验证 `Win+Shift+S` 首次直接粘贴 |
| T09 | P1 | 文件与拖拽 | 小文件、中文文件名、文件夹与大文件完整性正常，无意外覆盖 |
| T10 | P1 | 传输负载 | 传大文件时键鼠仍可用，无明显持续卡顿 |
| T11 | P1 | 多屏与 DPI | 实际分辨率、缩放与跨屏边界准确，外接屏热插拔行为明确 |
| T12 | P1 | 高权限 / 锁屏 | 在不降低安全设置前提下按官方支持范围测试，限制如实记录 |
| T13 | P0 | 常驻稳定性 | 连续办公/闲置周期 CPU、内存正常，无异常断连（建议观察 24–72h） |
| T14 | P2 | 增强功能 | 音频/麦克风转发按需开启，不破坏现有音频设备 |
