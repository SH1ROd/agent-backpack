# Windows 11 25H2 更新后右键菜单恢复为新样式

- 记录日期：2026-11-28
- 状态：已解决（Windhawk 2.0.0-alpha.8 + `explorer-context-menu-classic` 1.0.2）
- 当前系统：Windows 11 Pro 25H2，10.0.26200，UBR 9974
- 现象：用户此前通过注册表把 Windows 11 右键菜单改成 Windows 10 经典样式；近期系统更新后，右键菜单又变回 Windows 11 新菜单。

## 结论摘要

- 这不是恶意程序，也不是右键菜单被第三方软件篡改。
- 旧的经典菜单注册表键 **仍然存在**，但 Windows 11 25H2 新增的右键菜单状态层/设置页覆盖了它的效果。
- 无法精确证明是哪一个 KB 改的：Windows 不记录“右键菜单样式”这类设置开关的历史。能确认的是当前系统已处于 25H2，新设置页和新菜单状态层存在，与用户观察到变化的时间吻合。
- 2026-11-28 实测：官方设置页的“显示更多选项”只会增加入口；纯注册表经典键在 25H2 上被忽略。最终使用 **Windhawk + `explorer-context-menu-classic` mod** 实现默认经典菜单（见“最终处理”）。

## 环境与时间线

```text
当前系统:   Windows 11 Pro 25H2
Build:      26200.9974
安装日期:   2025-02-22
最近更新:   KB5132061 (2026-11-13)
            KB5132688 (2026-11-12)
            KB5127690 (2026-10-29)
            KB5054156 (2026-03-07)
```

系统 `HKLM:\SYSTEM\Setup` 中的 `Source OS` 记录显示更早的来源系统：

```text
Source OS: Windows 10 Pro 23H2
Build:     22631
更新记录:  2025-02-21 06:09
```

这属于设备更早的系统升级/镜像记录，不影响当前判断：当前实际运行的是 Windows 11 25H2，右键菜单是 Windows 11 新菜单。

## 证据

### 1. 旧的经典菜单键仍在

```text
HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32
默认值: 空
```

这是 Windows 11 上常见的“恢复 Windows 10 经典右键菜单”注册表做法。键存在，但当前菜单仍是新样式。

### 2. 25H2 新增了右键菜单状态层

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ContextMenu
  DefaultState\
  Preferences\
```

`Preferences` 中可见菜单定制提示相关计数，说明系统已经在使用新的右键菜单个性化状态。

### 3. 新设置页的“旧版菜单”开关是关闭的

“设置 → 个性化 → 上下文菜单”页面底部：

```text
显示更多选项
显示旧版上下文菜单    [关]
```

当前为关闭状态，对应新菜单样式。

### 4. 没有可回读的旧设置副本

- `C:\Windows.old` 不存在（升级旧系统副本已清理）。
- `C:\Windows\System32\config\RegBack` 为空。
- 系统还原点查询被拒绝/不可用。
- Windows 设置不提供逐项开关的变更历史。

因此无法还原“用户以前具体在哪一天把哪个开关改成了什么”，只能看到当前状态和升级/更新痕迹。

## 根因分析

### 已证实

1. 系统当前是 Windows 11 25H2。
2. 旧的经典菜单 CLSID 键仍然存在且默认值为空。
3. Windows 11 25H2 存在新的 `Explorer\ContextMenu` 状态层和新设置页。
4. 新设置页中的“显示旧版上下文菜单”开关为关闭状态。
5. 没有旧系统副本或还原点可用于读取旧设置。

### 最可能的机制（推断）

Windows 11 的经典菜单 tweak 依赖一个未公开/非官方的 COM 覆盖点。25H2 引入新的右键菜单状态和设置页后，菜单行为由新的状态层决定；旧的 CLSID 键虽然还在，但不再足以强制经典菜单。功能更新或累积更新可能重置/忽略了旧行为，导致菜单回到新样式。

**无法确认具体 KB**：Windows 不会为这类 UI 开关写事件日志，也没有设置变更历史。最近更新的时间与现象吻合，但只能作为关联证据，不能作为精确因果证明。

## 处理方案

### 方案 A：使用官方设置（优先）

1. 打开“设置 → 个性化 → 上下文菜单”。
2. 打开底部 **“显示更多选项”（说明为“显示旧版上下文菜单”）**。
3. 如果右键菜单没有立即变化，重启 Explorer：

   ```powershell
   Stop-Process -Name explorer -Force
   ```

   资源管理器会自动重启；已打开的文件资源管理器窗口会关闭，但不会影响其他程序。

> **2026-11-28 实测（Windows 11 25H2 build 26200）**：把 `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ContextMenu\Preferences\ShowMore\Enabled` 设为 `1` 后，只会在新右键菜单中出现“显示更多选项”入口，**不会让经典菜单成为默认**。如果目标是“默认就是 Windows 10 菜单、不需要每次再点一次”，本方案不够。

### 方案 B：注册表方式（官方设置无效时再试）

先备份相关键：

```powershell
reg export "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}" "$env:USERPROFILE\Desktop\classic-menu-backup.reg" /y
reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ContextMenu" "$env:USERPROFILE\Desktop\context-menu-state-backup.reg" /y
```

重新应用经典菜单键：

```powershell
$key = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name "(Default)" -Value ""
Stop-Process -Name explorer -Force
```

如果 25H2 仍然忽略该键，回到方案 A 的设置页开关。

### 方案 C：用户态 shell 补丁（注册表无效时）

Windows 11 24H2/25H2 对纯注册表经典菜单方案的支持不稳定，多个社区报告旧 CLSID 键写入成功但 Explorer 仍显示新菜单。如果方案 B 也无效，只能使用用户态 shell 补丁：

- **Windhawk + “Classic context menu on Windows 11” mod**
  `explorer-context-menu-classic`。通过内存注入实现，启用后默认显示经典菜单，按 Ctrl 右键可临时查看新菜单；可随时禁用 mod 或卸载。适合只想恢复右键菜单、不想改系统文件的场景。
- **ExplorerPatcher**
  File Explorer 设置中的 “Disable the immersive context menu” 可直接恢复 Windows 10 菜单。功能更全，但会注入/修改 Explorer，升级后可能失效，需要跟随版本更新。

这类工具属于第三方系统补丁，不是微软官方支持的功能。使用前应从官方项目/发布页下载，了解杀软误报、更新后失效和卸载回退方式；企业/受管设备可能被策略阻止。

## 最终处理（2026-11-28 已验证）

官方设置和纯注册表方案都不满足“默认经典菜单”后，本机最终采用：

```text
Windhawk: 2.0.0-alpha.8（官方 alpha；稳定版 1.7.3 没有 CLI）
Mod:      explorer-context-menu-classic 1.0.2（作者 m417z）
State:    enabled
Service:  Windhawk，Automatic，Running
```

实际效果：

- 右键直接显示 Windows 10 经典菜单，不需要再点“显示更多选项”。
- 按住 **Ctrl** 再右键，可临时查看 Windows 11 新菜单。
- Windhawk UI 窗口只是管理界面，可以关闭；真正生效的是 Session 0 的 `Windhawk` 服务。
- 实测关闭 Session 1 的 `windhawk.exe` UI/托盘后，服务仍为 Running，mod 仍为 enabled，经典菜单继续生效；托盘图标消失。
- `WindhawkRunBrokerTask` 是无触发器的按需 runtime broker（`windhawk-ui.exe --runtime-broker`），不是登录自启，不要禁用。
- 不要禁用/卸载 Windhawk 服务；否则 mod 停止，Explorer 重启后会回到新菜单。

安装/启用记录（管理员权限）：

```powershell
# 1. 安装 Windhawk 2.0 alpha（本机使用官方 setup，/S /STANDARD）
#    或从 windhawk.net / GitHub releases 下载安装包

# 2. 用 CLI 安装并启用 mod（需要管理员）
& "C:\Program Files\Windhawk\windhawk-cli.exe" mod install explorer-context-menu-classic --yes
& "C:\Program Files\Windhawk\windhawk-cli.exe" mod list
```

`mod install` 第一次非管理员运行会报 `拒绝访问 ... hint: run this command as administrator`，需要 UAC 提升。

卸载/回退：

```powershell
# 只关闭经典菜单，保留 Windhawk
& "C:\Program Files\Windhawk\windhawk-cli.exe" mod disable explorer-context-menu-classic

# 移除 mod
& "C:\Program Files\Windhawk\windhawk-cli.exe" mod remove explorer-context-menu-classic --yes

# 彻底卸载 Windhawk
& "C:\Program Files\Windhawk\uninstall.exe"
# 或 winget uninstall --id RamenSoftware.Windhawk -e
```

移除后重启 Explorer，菜单会恢复为 Windows 11 新样式。

**风险提示：**

- Windhawk 是第三方系统 mod 加载器，会以管理员服务运行并向 Explorer 注入代码；只从官方 GitHub/官网获取，保持更新。
- 本机使用的是 2.0 alpha；如果遇到稳定性问题，可卸载后改用稳定版 UI 安装同一个 mod。
- Windows 功能更新后，Windhawk 或 mod 可能需要更新；这比注册表方案更依赖工具兼容性，但也是 25H2 上能实现“默认经典菜单”的可行方式。

### 回退到新菜单

```powershell
# 方法 1：设置页把“显示更多选项”关掉
# 方法 2：删除经典菜单键并重启 Explorer
Remove-Item -Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}" -Recurse -Force
Stop-Process -Name explorer -Force
```

如果使用过注册表备份，也可以双击 `.reg` 备份文件恢复。

## 验证方式

1. 在桌面或文件资源管理器空白处右键，观察是新菜单还是经典菜单。
2. 检查经典菜单键：

   ```powershell
   Test-Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
   (Get-Item "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32").GetValue("")
   ```

3. 检查系统版本和更新：

   ```powershell
   Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,InstallDate
   Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10
   ```

## 经验

1. **键存在 ≠ 行为生效。** Windows 新版本可能增加更高优先级的状态层或官方设置页，旧 tweak 会失效但不会被删除。
2. **优先官方 Settings 开关。** 25H2 已有“显示旧版上下文菜单”开关时，不要只依赖旧的 CLSID hack。
3. **改 UI 前先导出相关注册表。** 备份比“记住自己改过什么”可靠。
4. **记录系统版本和更新时间。** 下次出现类似变化时，先核对 build/更新，而不是先怀疑恶意软件。
5. **Windows 没有设置变更历史。** 这类问题的“历史记录”只能靠本地笔记、注册表备份和更新日志拼出来。
6. **区分无关弹窗。** 同一天出现的 `EqualizerAPO\UpdateChecker.exe` 网络错误弹窗属于音频软件自身更新检查，与本问题无关。
7. **功能更新后复查 tweak。** Windows 11 25H2 这类功能层更新后，旧注册表技巧可能被新 UI 取代；升级后重新验证并更新本笔记。
8. **mod 加载器和 mod 是两层。** 关掉 Windhawk UI 不影响 mod；必须保留 `Windhawk` 后台服务。反之，卸载服务/工具会让 UI 定制一起消失。
9. **官方开关不等于默认行为。** 25H2 的 `ShowMore.Enabled=1` 只是把入口加回来；不要把“有入口”误判为“默认经典菜单”。

## 诊断命令汇总

```powershell
# 当前系统
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,InstallDate

# 来源系统/升级痕迹
Get-ChildItem "HKLM:\SYSTEM\Setup" | Where-Object { $_.PSChildName -like "Source OS*" }

# 旧经典菜单键
$legacy = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
Test-Path $legacy
if (Test-Path $legacy) { (Get-Item $legacy).GetValue("") }

# 新右键菜单状态
Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ContextMenu" -Recurse

# 旧系统副本/备份
Test-Path "C:\Windows.old"
Get-ChildItem "C:\Windows\System32\config\RegBack" -ErrorAction SilentlyContinue
```
