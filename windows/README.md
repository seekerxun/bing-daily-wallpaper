# Bing 每日壁纸自动更新（Windows）

使用 Windows 自带的 Windows PowerShell 5.1 和官方 `IDesktopWallpaper` 接口，每天获取 Bing UHD 图片，并在登录后及登录期间每小时检查一次所有物理显示器。默认地区为中国区 `zh-CN`，显示方式为“填充（Fill）”。

支持 64 位 Windows 10 和 Windows 11。不需要管理员权限，不安装 Python、Node.js、PowerShell 7 或第三方模块。

## 文件说明

- `bing_wallpaper.ps1`：下载、验证、设置并逐显示器复核壁纸，保存状态、写日志和清理旧图。
- `install.ps1`：把主脚本复制到稳定的当前用户目录，并幂等注册计划任务。
- `uninstall.ps1`：删除任务和程序副本；默认保留图片、状态、日志和当前壁纸。
- `test.ps1`：不修改真实壁纸、不访问外网的辅助测试。

## 安装

打开普通权限的 Windows PowerShell，进入仓库的 `windows` 目录后执行：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

`ExecutionPolicy Bypass` 仅作用于这一次进程，不会修改用户或计算机的永久执行策略。安装程序会立即运行一次主脚本。

安装后的路径：

```text
程序：%LOCALAPPDATA%\BingWallpaper\bing_wallpaper.ps1
图片：<系统“图片”目录>\BingWallpapers\bing_yyyy-MM-dd.jpg
状态：<系统“图片”目录>\BingWallpapers\.last_url
日志：<系统“图片”目录>\BingWallpapers\bing_wallpaper.log
任务：Bing Daily Wallpaper
```

系统“图片”目录通过 .NET 获取；如果已迁移到 OneDrive，会自动使用迁移后的真实位置。

## 常用命令

立即手动运行安装副本：

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\BingWallpaper\bing_wallpaper.ps1"
```

查看任务和上次运行结果：

```powershell
Get-ScheduledTask -TaskName 'Bing Daily Wallpaper' | Get-ScheduledTaskInfo
```

手动启动任务：

```powershell
Start-ScheduledTask -TaskName 'Bing Daily Wallpaper'
```

查看最近 50 行日志：

```powershell
$dir = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)) 'BingWallpapers'
Get-Content -LiteralPath (Join-Path $dir 'bing_wallpaper.log') -Tail 50
```

运行离线辅助测试：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\test.ps1
```

## 修改地区和更新程序

默认地区写在 `bing_wallpaper.ps1` 的参数中。可手动指定地区：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bing_wallpaper.ps1 -Market en-US
```

地区代码必须使用 `zh-CN`、`en-US`、`ja-JP` 这类大小写格式。计划任务使用脚本默认值；若要永久修改任务使用的地区，可修改主脚本默认值后重新运行 `install.ps1`。更新仓库脚本后同样重新安装，安装过程是幂等的。

## 卸载

默认卸载保留下载图片、`.last_url`、日志和当前正在显示的壁纸：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

只有明确需要一并删除下载目录时才使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveDownloadedImages
```

删除下载目录前，脚本会重新确认它是系统“图片”目录的直接子目录 `BingWallpapers`，并拒绝递归删除重解析点。卸载不会删除仓库源文件。

## 多显示器和虚拟桌面

脚本使用官方 `IDesktopWallpaper` COM 接口枚举当前连接的物理显示器，对全部显示器设置同一张图片，并逐个读取实际路径进行验证。任一显示器不匹配时不会更新 `.last_url`，任务返回非零退出码。

Windows 虚拟桌面与物理显示器是不同机制。公开的 `IDesktopWallpaper` 接口没有稳定的逐虚拟桌面管理能力。本项目不使用 Explorer 私有接口、`IVirtualDesktopManagerInternal` 或未公开注册表结构。因此，Windows 11 中曾为不同虚拟桌面单独配置的壁纸是否全部统一，取决于系统版本行为；请以当前系统实际显示为准。

## 本机验收记录（2026-08-12）

测试环境：Windows NT 10.0.26200.0，64 位；Windows PowerShell 5.1.26100.8875；普通用户、非管理员。

已实机通过：

- 首次联网下载约 3.6 MB 的 Bing `zh-CN` UHD JPEG，文件头、大小和 `System.Drawing` 解码验证成功。
- 使用 `IDesktopWallpaper` 设置并回读验证 5 个已连接物理显示器，全部指向当天图片，显示方式为 Fill。
- 连续运行不重复下载，但仍逐显示器复核；计划任务手动启动成功，上次运行结果为 `0`。
- 计划任务 XML 为当前用户 `InteractiveToken`、最低权限、登录触发、`PT1H` 无限重复、`IgnoreNew`、允许电池运行、`StartWhenAvailable`、10 分钟执行上限。
- 当天图片被移走、被文本内容损坏时，脚本均重新下载并恢复。
- 手动换成测试壁纸后，下一次运行恢复当天 Bing 图片，5 个显示器全部通过回读验证。
- 模拟元数据网络连接失败时返回 `1`；原 JPEG 和 `.last_url` 的 SHA-256 均未变化，无 `.tmp` 遗留。
- 持有同名 Mutex 模拟并发实例时，第二个实例返回 `0` 并安全退出。
- 默认卸载保留图片、状态和日志；连续执行两次均成功。显式 `-RemoveDownloadedImages` 只删除目标子目录，系统“图片”目录保持完整；随后重新安装成功。
- PowerShell 5.1 离线语法与辅助测试通过。

尚未实机验证：

- 注销后重新登录的触发过程，以及睡眠错过整点后 `StartWhenAvailable` 的实际唤醒表现；这些操作会中断当前 Codex 会话。
- Windows 11 多虚拟桌面的三种交互场景；本次没有自动创建、切换或删除用户虚拟桌面。
- 断开并重新连接物理显示器；本次只验证了当前已连接的 5 个显示器。

## 常见故障

### 网络失败

脚本会重试 3 次并记录原始异常。本次失败不会覆盖现有图片或 `.last_url`，下一个小时会再次尝试。

### 企业策略禁止壁纸或计划任务

企业组策略可能禁止修改壁纸或禁止普通用户注册计划任务。安装程序会显示实际错误，并保留已复制程序的位置和手动运行命令；本项目不会绕过策略或保存管理员凭据。

### 任务没有运行

先检查：

```powershell
Get-ScheduledTask -TaskName 'Bing Daily Wallpaper'
Get-ScheduledTaskInfo -TaskName 'Bing Daily Wallpaper'
```

任务仅使用当前用户的交互登录令牌。刚安装时会由安装程序直接运行一次；登录触发器的每小时重复周期从下一次匹配的登录事件开始。

### 主题、Spotlight 或其他软件替换壁纸

脚本每小时都会逐显示器检查，即使 Bing URL 没变也不会直接退出。检测到路径或 Fill 显示方式变化后会自动恢复。如果其他软件持续抢占壁纸，两者可能反复覆盖，建议只保留一个自动壁纸来源。

### 图片目录迁移

不要硬编码 `C:\Users\用户名\Pictures`。脚本每次都通过系统 API 获取当前“图片”目录；可从日志确认实际保存位置。
