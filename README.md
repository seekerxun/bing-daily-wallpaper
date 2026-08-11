# Bing 每日壁纸自动更新

自动获取 Bing 每日壁纸并设置为 macOS 桌面壁纸，通过 LaunchAgent 实现用户登录后自动启动和后台定时运行。

Windows 10/11 用户请参阅 [Windows 版安装与使用说明](windows/README.md)。Windows 版使用系统自带 PowerShell 5.1、官方多显示器接口和当前用户计划任务，不影响下方现有 macOS 用法。

## 文件说明

- `bing_wallpaper.sh` — 主脚本（**源文件**），负责获取当日 Bing 壁纸、下载 UHD 图片、核对并设置桌面壁纸、清理旧文件。
- `sync_all_spaces.py` — 桌面空间同步工具，按 macOS 「在所有空间中显示」的配置结构统一所有空间，并在每次修改前自动备份原配置。
- `com.seekerxun.bingwallpaper.plist` — LaunchAgent 配置文件，控制脚本的启动和定时运行。

> ⚠️ **重要约定：LaunchAgent 运行的是脚本副本，不是项目内的源文件。**
>
> 安装时会把源脚本复制到 `~/Library/Scripts/bing_wallpaper.sh`，LaunchAgent 实际执行该副本。在当前 macOS 权限配置下，launchd 派生的进程访问 `~/Documents`、`~/Desktop` 或 `~/Downloads` 中的脚本可能被 TCC 拦截，并报 `Operation not permitted`。因此 plist 的 `ProgramArguments` 必须指向 `~/Library/Scripts/` 中的副本。

## 工作原理

1. 调用 Bing `HPImageArchive.aspx` 接口获取当日壁纸信息，默认使用中国区 `zh-CN`。
2. 与上次已成功设置的图片 URL 比对，避免重复下载。
3. URL 变化或本地当日图片缺失时，下载 UHD 版本。下载先写入临时文件，验证为 JPEG 后再替换正式文件，避免网络中断留下损坏图片。
4. 每次成功获取 Bing 信息后，核对当前可见桌面，并检查 `Index.plist` 里全部 Space/Display 是否都指向当日图片（`System Events` 看不到未激活的桌面 2 等空间）。
5. 如果壁纸被替换，或任一桌面空间仍是旧图，脚本会自动恢复当日图片并同步到所有桌面空间和显示器。
6. 通过 `osascript` 设置可见桌面壁纸后，同步工具会写入共用配置、更新/清空各 Space 覆盖项，并在 WallpaperAgent 重启后重试写入，避免午夜换图时 Agent 用内存态把 Index 写回旧壁纸。
7. 清理保存目录中超过 7 天的 `bing_*.jpg` 旧壁纸。

## 安装

在本机「终端」App 中执行：

```bash
mkdir -p ~/Library/Scripts ~/Library/LaunchAgents ~/Pictures/BingWallpapers
install -m 755 ~/Documents/LifeSpace/Bing壁纸自动更新/bing_wallpaper.sh ~/Library/Scripts/bing_wallpaper.sh
install -m 755 ~/Documents/LifeSpace/Bing壁纸自动更新/sync_all_spaces.py ~/Library/Scripts/sync_all_spaces.py
install -m 600 ~/Documents/LifeSpace/Bing壁纸自动更新/com.seekerxun.bingwallpaper.plist ~/Library/LaunchAgents/com.seekerxun.bingwallpaper.plist
launchctl bootout gui/$(id -u)/com.seekerxun.bingwallpaper 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.seekerxun.bingwallpaper.plist
launchctl kickstart -k gui/$(id -u)/com.seekerxun.bingwallpaper
```

任务安装后会立即执行一次，之后每小时检查一次。

`StartInterval` 在 Mac 睡眠期间不会补跑错过的执行。唤醒后会等待后续的定时间隔；如果需要立即检查，可使用下方的 `kickstart` 命令。

> 脚本会使用 macOS 官方的「在所有空间中显示」开关，让桌面 1、桌面 2 以及所有已连接显示器共用同一张当日壁纸。

## 运行状态

- **桌面壁纸**：成功运行后，桌面 1、桌面 2 等所有桌面空间和已连接显示器应显示同一张当天 Bing 图片。
- **图片目录**：`~/Pictures/BingWallpapers`。
- **主日志**：`~/Pictures/BingWallpapers/bing_wallpaper.log`，记录「所有桌面空间已统一」、「自动恢复」或错误信息。
- **标准错误**：`~/Pictures/BingWallpapers/launchd_stderr.log`，记录脚本未捕获的错误。
- **活动监视器**：任务运行时进程名显示为 `bash`，这是正常的。
- **LaunchAgent 状态**：任务只在检查时短暂运行，因此 `state = not running` 通常是正常的；同时确认 `last exit code = 0` 即可。

## 常用管理命令

```bash
# 停止并卸载自动任务
launchctl bootout gui/$(id -u)/com.seekerxun.bingwallpaper

# 重新加载自动任务
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.seekerxun.bingwallpaper.plist

# 立即执行一次，不等待下一个定时间隔
launchctl kickstart -k gui/$(id -u)/com.seekerxun.bingwallpaper

# 查看任务状态
launchctl print gui/$(id -u)/com.seekerxun.bingwallpaper

# 查看最近 50 行主日志
tail -n 50 ~/Pictures/BingWallpapers/bing_wallpaper.log

# 查看未捕获的标准错误
tail -n 50 ~/Pictures/BingWallpapers/launchd_stderr.log
```

## 自定义配置

脚本开头包含两个常用配置：

- `MARKET`：地区代码，默认为 `zh-CN`，也可改为 `en-US`、`ja-JP` 等。
- `SAVE_DIR`：壁纸保存目录，默认为 `~/Pictures/BingWallpapers`。

plist 中的 `StartInterval` 是检查间隔，单位为秒，默认值 `3600` 表示每小时检查一次。

### 修改脚本后同步

只修改项目内的源脚本不会自动更新 LaunchAgent 正在使用的副本。修改后执行：

```bash
install -m 755 ~/Documents/LifeSpace/Bing壁纸自动更新/bing_wallpaper.sh ~/Library/Scripts/bing_wallpaper.sh
install -m 755 ~/Documents/LifeSpace/Bing壁纸自动更新/sync_all_spaces.py ~/Library/Scripts/sync_all_spaces.py
launchctl kickstart -k gui/$(id -u)/com.seekerxun.bingwallpaper
```

只修改脚本时无需重新加载 LaunchAgent；`kickstart` 会立即使用新副本运行一次。

### 修改 plist 后重新加载

修改 `StartInterval` 或其他 plist 设置后，必须重新加载任务：

```bash
install -m 600 ~/Documents/LifeSpace/Bing壁纸自动更新/com.seekerxun.bingwallpaper.plist ~/Library/LaunchAgents/com.seekerxun.bingwallpaper.plist
launchctl bootout gui/$(id -u)/com.seekerxun.bingwallpaper 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.seekerxun.bingwallpaper.plist
launchctl kickstart -k gui/$(id -u)/com.seekerxun.bingwallpaper
```

## 常见问题

### `launchctl bootstrap` 加载失败

1. 检查 plist 语法：

   ```bash
   plutil -lint ~/Library/LaunchAgents/com.seekerxun.bingwallpaper.plist
   ```

2. 确认 plist 的 `ProgramArguments` 指向 `~/Library/Scripts/bing_wallpaper.sh`，而不是 `~/Documents` 中的源文件。
3. 确认脚本和 plist 都存在、归当前用户所有，且 plist 不允许组或其他用户写入。
4. 如果任务已经加载，先执行 `bootout`，再执行 `bootstrap`。
5. 该任务是需要图形登录会话的 LaunchAgent，建议在本机「终端」App 内操作。

### 日志显示「设置壁纸失败」

`osascript` 需要在当前图形登录会话中访问 `System Events`。请确认：

- 当前用户已登录 macOS 桌面。
- 「系统设置 → 隐私与安全性 → 自动化」中的相关 `System Events` 授权没有被拒绝。
- 通过 `kickstart` 再次测试，然后检查主日志和 `launchd_stderr.log`。

非图形 shell 和未获授权的 LaunchAgent 都可能设置失败，不应仅根据下载成功就判断壁纸已生效。

### 桌面壁纸很久没更新

1. 查看 `bing_wallpaper.log`。「所有桌面空间已统一使用当日图片」表示当前正常；「已恢复并同步所有桌面空间」表示脚本已自动修复。
2. 如果没有新日志，执行 `launchctl print gui/$(id -u)/com.seekerxun.bingwallpaper` 检查任务是否已加载。
3. 执行 `launchctl kickstart -k gui/$(id -u)/com.seekerxun.bingwallpaper` 立即运行一次，然后再看日志。
4. 如果 Mac 之前在睡眠，`StartInterval` 不会补跑睡眠期间错过的执行，这属于 launchd 的正常行为。
