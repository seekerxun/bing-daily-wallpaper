# Bing 每日壁纸自动更新：Windows 版实施规格

> 本文档是交给 Windows 机器上 AI/开发者的完整实施任务书。请在 Windows 10 或 Windows 11 实机上，基于当前仓库实现并验证 Windows 版本。不要只给出示例代码或方案说明，应当创建全部文件、安装到本机、运行测试，并根据实机结果修复问题。

## 1. 项目背景

当前仓库已经有可工作的 macOS 版本：

- `bing_wallpaper.sh`：获取 Bing 当日壁纸、下载 UHD 图片、设置壁纸、校验结果、记录日志并清理旧图片。
- `sync_all_spaces.py`：处理 macOS 多桌面空间与多显示器同步。
- `com.seekerxun.bingwallpaper.plist`：通过 LaunchAgent 在登录后启动，并每小时检查一次。
- `README.md`：macOS 版本的安装和使用说明。

现在需要新增一个原生 Windows 版本，实现尽可能一致的体验。macOS 文件必须保留，不要改写为跨平台脚本，也不要破坏现有 macOS 用法。

## 2. 最终目标

Windows 版应做到：

1. 当前用户登录 Windows 后自动运行一次。
2. 登录期间每小时检查一次 Bing 当日壁纸。
3. 默认获取 Bing 中国区 `zh-CN` 的当日图片。
4. 下载 Bing 提供的 UHD JPEG，而不是低分辨率缩略图。
5. 把图片设置为所有已连接物理显示器的桌面壁纸。
6. 默认使用 Windows 的“填充（Fill）”显示方式。
7. 即使图片 URL 没变化，也要检查当前壁纸是否被用户、主题或其他程序替换；如被替换，应自动恢复。
8. 下载失败、文件损坏或设置失败时，不得覆盖现有的有效图片和状态。
9. 图片保留 7 天，自动清理更早的 `bing_*.jpg`。
10. 提供明确的中文日志、安装脚本、卸载脚本和 Windows 使用说明。
11. 正常安装应以当前用户身份完成，原则上不要求管理员权限。
12. 不安装 Python、Node.js、PowerShell 7 或第三方模块；使用 Windows 自带能力运行。

## 3. 目标平台与明确边界

### 3.1 支持范围

- Windows 10 桌面版，64 位。
- Windows 11 桌面版，64 位。
- Windows PowerShell 5.1。
- 单显示器和多显示器。
- 普通本地账户、Microsoft 账户或域账户，只要该账户能创建自己的计划任务并修改个人壁纸。

### 3.2 暂不支持

- Windows 7、Windows 8.1。
- Windows Server、无图形桌面的环境。
- Windows 锁屏图片。
- Microsoft Store 发布、MSIX 安装包、托盘常驻程序或图形设置界面。
- 绕过企业组策略强制设置的壁纸。
- 使用未公开的 Windows 虚拟桌面 COM 接口或直接修改虚拟桌面内部注册表结构。

### 3.3 虚拟桌面说明

Windows 的“物理显示器”和“虚拟桌面”不是同一个概念。官方 `IDesktopWallpaper` 接口明确支持对一个或全部物理显示器设置壁纸，但没有公开提供逐个管理 Windows 11 虚拟桌面壁纸的稳定接口。

第一版必须可靠覆盖所有已连接的物理显示器。需要在 Windows 11 实机上额外记录以下测试结果：

1. 只有默认虚拟桌面时是否正常。
2. 创建桌面 2 后，在桌面 1 执行脚本，桌面 2 最终显示什么。
3. 如果桌面 1 和桌面 2 之前分别设置过不同壁纸，脚本运行后表现如何。

如果官方接口不能统一全部虚拟桌面，应在 Windows README 中如实写成已知限制。不要为了实现这一点使用 `IVirtualDesktopManagerInternal`、Explorer 私有接口或未经确认的注册表修改。这些方式容易随 Windows 更新失效。

## 4. 交付文件

在仓库中新建 `windows` 目录，并至少交付：

```text
windows/
├── bing_wallpaper.ps1   # 主程序
├── install.ps1          # 当前用户安装与计划任务注册
├── uninstall.ps1        # 卸载计划任务和程序文件
└── README.md            # Windows 专用说明
```

可选但推荐增加：

```text
windows/
└── test.ps1             # 不访问真实 Bing 时可运行的辅助测试
```

根目录 `README.md` 可以增加一个简短的“Windows 版本”入口，链接到 `windows/README.md`，但不要删除或大幅改写现有 macOS 内容。

不要提交运行后生成的图片、日志、`.last_url`、临时文件或用户机器上的计划任务导出文件。

## 5. Windows 目录约定

### 5.1 安装目录

程序安装到当前用户本地应用数据目录：

```text
%LOCALAPPDATA%\BingWallpaper\
```

至少包含：

```text
%LOCALAPPDATA%\BingWallpaper\bing_wallpaper.ps1
```

不要把计划任务直接指向用户的 Documents、Downloads、桌面或 Git 仓库位置。安装脚本必须先复制稳定副本，再让任务计划程序执行该副本。

### 5.2 图片和状态目录

必须通过 .NET 获取系统实际的“图片”目录，不要拼接硬编码的 `C:\Users\用户名\Pictures`：

```powershell
[Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)
```

在其下使用：

```text
<系统图片目录>\BingWallpapers\
```

这个目录保存：

```text
bing_2026-08-12.jpg
.last_url
bing_wallpaper.log
```

如果系统“图片”目录被迁移到 OneDrive，也应使用迁移后的真实路径。

### 5.3 临时文件

临时下载文件必须创建在 `BingWallpapers` 目录中，确保验证后替换正式文件时位于同一磁盘卷。名称示例：

```text
.bing_wallpaper.<随机值>.tmp
```

无论成功或失败，都必须在 `finally` 中清理遗留临时文件。

## 6. 主脚本要求：`bing_wallpaper.ps1`

### 6.1 兼容性约束

- 必须在 Windows PowerShell 5.1 中运行，不得依赖 PowerShell 7 专属语法。
- 建议开启严格模式，并让未处理错误进入 `catch`：

  ```powershell
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  ```

- 不依赖外部 `curl.exe`、Python、Git Bash 或第三方 PowerShell 模块。
- 在需要时显式启用 TLS 1.2，以兼容较旧的 Windows PowerShell 5.1 默认网络设置。
- 所有文件路径都要支持空格、中文用户名和非 ASCII 字符。
- 不要通过字符串拼接执行命令，不要使用 `Invoke-Expression`。

### 6.2 默认配置

脚本开头保留容易修改的配置，默认值如下：

```text
MARKET = zh-CN
RETENTION_DAYS = 7
CHECK_INTERVAL = 由计划任务控制，每小时一次
WALLPAPER_POSITION = Fill
```

可额外提供参数覆盖，例如：

```powershell
param(
    [string]$Market = 'zh-CN',
    [int]$RetentionDays = 7
)
```

如果提供参数，必须校验：

- `Market` 只接受形如 `zh-CN`、`en-US`、`ja-JP` 的地区代码。
- `RetentionDays` 必须是合理的正整数，例如 1 到 365。

不要为了配置引入复杂的注册表写入。第一版使用脚本参数或脚本顶部默认值即可。

### 6.3 防止并发运行

计划任务必须配置为已有实例运行时忽略新实例。此外，主脚本自身还应使用命名 Mutex 或等效机制防止“手动运行”和“计划任务运行”重叠。

要求：

- 如果检测到另一个实例正在运行，记录一条日志并以成功状态退出。
- Mutex 必须在 `finally` 中释放和销毁。
- 不要用一个可能永久遗留的普通锁文件作为唯一并发保护。

### 6.4 日志

日志写入：

```text
<系统图片目录>\BingWallpapers\bing_wallpaper.log
```

每行格式：

```text
[2026-08-12 14:30:00] 信息内容
```

至少记录：

- 脚本开始和结束。
- 获取 Bing 元数据失败。
- 解析 URL 失败。
- 开始下载、下载成功、下载文件验证失败。
- 当前图片已经是当日图片。
- 当前壁纸被替换并已恢复。
- 所有显示器设置成功。
- 某个显示器验证失败。
- 删除了哪些过期图片，或者删除数量。
- 计划任务/策略/权限相关错误的原始异常信息。

日志不应记录密码、令牌或无关的完整环境变量。日志写入失败时，应至少把错误输出到控制台。

### 6.5 获取 Bing 元数据

接口：

```text
https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=zh-CN
```

其中 `mkt` 使用配置的地区代码，并进行正确的 URL 编码。

要求：

1. 使用 `Invoke-RestMethod` 或基于 .NET 的 HTTP 请求。
2. 设置合理超时，建议 120 秒以内。
3. 发生网络错误时重试 3 次；重试之间使用短暂递增等待，例如 1、2、4 秒。
4. HTTP 非成功状态、JSON 无法解析、`images` 为空、`urlbase` 缺失都属于失败。
5. 不要使用正则表达式从整段 JSON 中硬抠字段；应解析 JSON 对象。
6. 失败时不要修改 `.last_url`，不要删除当前有效壁纸，也不要把空文件设为壁纸。

从第一个图片对象读取 `urlbase`，组合 UHD 地址：

```text
https://www.bing.com<urlbase>_UHD.jpg
```

PowerShell 字符串插值时注意变量与 `_UHD` 的边界，例如使用 `$($urlBase)`。

### 6.6 选择本地文件名

日期使用当前 Windows 本地日期：

```text
yyyy-MM-dd
```

正式图片路径：

```text
<保存目录>\bing_yyyy-MM-dd.jpg
```

读取 `.last_url` 时应去掉首尾空白。以下任一条件成立时必须重新下载：

- 当前 UHD URL 与 `.last_url` 不同。
- 当天正式图片不存在。
- 当天正式图片长度为 0。
- 当天正式图片无法通过 JPEG 验证。

即使 URL 没变化且图片有效，也不能直接退出；仍需检查所有显示器当前是否使用该图片。

### 6.7 安全下载与 JPEG 验证

下载必须先写入随机临时文件，不能直接覆盖正式图片。

建议流程：

1. 创建保存目录。
2. 在保存目录生成唯一临时文件名。
3. 下载到临时文件。
4. 检查文件存在且长度大于合理下限，例如 10 KB。
5. 检查 JPEG 文件头至少以 `FF D8 FF` 开始。
6. 推荐再用 `System.Drawing.Image.FromFile()` 实际解码，确认格式和宽高有效；对象必须及时 `Dispose()`，避免锁住文件。
7. 验证成功后，以同卷移动/替换方式更新正式图片。
8. 验证失败时删除临时文件，保留原正式图片。

不要只相信 HTTP `Content-Type`，因为错误页面、代理登录页或网关提示也可能被保存下来。

### 6.8 设置 Windows 壁纸

优先使用 Windows 官方 `IDesktopWallpaper` COM 接口，而不是只修改注册表，也不要把 `SystemParametersInfo(SPI_SETDESKWALLPAPER)` 作为主方案。

原因：

- `IDesktopWallpaper` 从 Windows 8 开始受支持。
- 能枚举物理显示器。
- 能对全部显示器或指定显示器设置壁纸。
- 能读取每个显示器的当前壁纸并进行验证。
- 能设置 Fill/Fit/Span 等显示模式。

PowerShell 5.1 不能可靠地通过动态 `System.__ComObject` 调用一个只继承 `IUnknown`、不提供 `IDispatch` 的接口。因此建议在 `bing_wallpaper.ps1` 内用 `Add-Type` 嵌入一小段 C#，声明：

- `IDesktopWallpaper` 接口。
- `DesktopWallpaper` COM coclass。
- `DESKTOP_WALLPAPER_POSITION` 枚举。
- 必要的 `RECT`、slideshow/status 类型。

注意事项：

1. `IDesktopWallpaper` 的 GUID、DesktopWallpaper CLSID、方法顺序和 Marshaling 必须与 Windows SDK 一致。
2. COM 接口使用 vtable，不能为了省事只声明后面的 `SetPosition` 而遗漏前置方法，否则方法槽位会错位，可能导致崩溃或调用错误函数。
3. DesktopWallpaper CLSID 为：

   ```text
   C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD
   ```

4. `SetWallpaper` 的 monitor ID 传 `null`，表示设置全部显示器。
5. 设置完整、绝对的本地 JPEG 路径。
6. 默认调用 `SetPosition(Fill)`；Fill 的枚举值必须以 Windows SDK 定义为准，不要凭记忆随意填写。
7. 如桌面背景被禁用，可调用官方接口重新启用，但不要修改与本项目无关的主题设置。
8. COM 对象使用结束后应释放，避免计划任务长期积累 Explorer/COM 资源。

官方参考：

- `IDesktopWallpaper`：<https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-idesktopwallpaper>
- `IDesktopWallpaper::SetWallpaper`：<https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-idesktopwallpaper-setwallpaper>
- `IDesktopWallpaper::GetWallpaper`：<https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-idesktopwallpaper-getwallpaper>
- `IDesktopWallpaper::SetPosition`：<https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-idesktopwallpaper-setposition>

### 6.9 设置后的验证

不能只因为 COM 调用没有抛异常就判断成功。

必须：

1. 调用 `GetMonitorDevicePathCount()` 获取显示器数量。
2. 对每个索引调用 `GetMonitorDevicePathAt()` 获取 monitor ID。
3. 对每个 monitor ID 调用 `GetWallpaper()`。
4. 将返回路径与目标图片路径规范化后进行不区分大小写比较。
5. 至少发现一个显示器，并且所有显示器都匹配，才算成功。

路径比较应考虑：

- Windows 路径不区分大小写。
- 相对路径和绝对路径必须先转换为完整路径。
- 尾随分隔符和简单的路径格式差异不应导致误判。

如果第一次设置后没有立即读到新状态，可以短暂重试，例如最多 10 次、每次等待 500 毫秒到 1 秒。最终仍不匹配时：

- 记录每个显示器返回的实际路径。
- 不更新 `.last_url`。
- 返回非零退出码。

### 6.10 状态更新顺序

`.last_url` 只能在以下条件全部满足后更新：

1. 当日图片文件存在且 JPEG 验证通过。
2. 壁纸设置调用成功，或者本来就已正确设置。
3. 每个已枚举物理显示器都验证为目标图片。

写 `.last_url` 也应先写临时状态文件，再移动替换，避免断电留下半写文件。

预期日志语义：

- URL 未变化、文件有效、显示器全部匹配：

  ```text
  所有显示器已使用当日图片：<路径>
  ```

- 下载了新图片并设置成功：

  ```text
  已下载 UHD 图片并应用到所有显示器：<路径>
  ```

- 用户或其他程序替换壁纸后恢复：

  ```text
  检测到壁纸被替换，已恢复到所有显示器：<路径>
  ```

### 6.11 旧图片清理

只允许在保存目录内清理名称严格匹配以下规则的普通文件：

```text
bing_*.jpg
```

要求：

- 删除最后写入时间早于配置保留天数的文件。
- 不删除今天正在使用的图片。
- 不跟随符号链接、目录联接点或重解析点去其他目录删除内容。
- 不删除 `.last_url`、日志、用户放入目录的其他图片或任何上级目录内容。
- 清理失败应记录日志，但不要让已经成功设置的壁纸被判定为整体失败。

## 7. 安装脚本要求：`install.ps1`

### 7.1 基本行为

安装脚本必须：

1. 验证它旁边存在 `bing_wallpaper.ps1`。
2. 创建 `%LOCALAPPDATA%\BingWallpaper`。
3. 把主脚本复制到该目录，覆盖旧版本。
4. 使用固定的、可预测的计划任务名称，例如：

   ```text
   Bing Daily Wallpaper
   ```

5. 如果同名任务已经存在，安全地更新/替换它，实现幂等安装。
6. 任务以当前交互用户、最低权限运行。
7. 安装完成后立即运行主脚本一次，不等待下一次登录或整点。
8. 输出安装位置、图片位置、日志位置、任务名称和首次运行结果。

### 7.2 PowerShell 路径和参数

计划任务使用系统自带 Windows PowerShell 5.1 的明确路径，通常为：

```text
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
```

参数：

```text
-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<安装目录>\bing_wallpaper.ps1"
```

`ExecutionPolicy Bypass` 只用于该计划任务进程，不得调用 `Set-ExecutionPolicy` 修改用户或机器的永久策略。

所有引号必须正确处理包含空格、中文或括号的路径。不要通过 `cmd.exe /c` 再套一层命令。

### 7.3 计划任务触发器

最符合当前 macOS 行为的方案是使用一个当前用户登录触发器，并在该触发器上配置无限重复：

- 当前用户登录时立即运行。
- 重复间隔：`PT1H`，即一小时。
- 不设置 `Duration`，表示无限重复，直到该登录会话结束。
- 用户下次登录会重新触发并开始新的每小时重复周期。

PowerShell 的 `New-ScheduledTaskTrigger -AtLogOn` 对无限重复模式的表达并不总是方便，因此可以使用任务计划程序 COM API或经过正确转义的任务 XML注册。不要用“创建一个十年后过期”的临时替代方案。

任务计划程序官方规定，`Repetition/Interval` 使用 ISO 8601 duration；`PT1H` 表示一小时，不提供 `Duration` 时无限重复：

- <https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-repetitiontype-complextype>
- <https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-duration-repetitiontype-element>

### 7.4 计划任务设置

任务至少应满足：

```text
LogonType                 = InteractiveToken
RunLevel                  = LeastPrivilege
MultipleInstancesPolicy   = IgnoreNew
StartWhenAvailable        = true
DisallowStartIfOnBatteries = false
StopIfGoingOnBatteries    = false
WakeToRun                 = false
ExecutionTimeLimit        = 10 分钟左右
Enabled                   = true
```

说明：

- 必须“仅在用户登录时运行”，否则后台非交互会话可能无法正确修改该用户的可见桌面。
- 允许使用电池时运行，因为脚本通常只短暂执行。
- 不需要为了壁纸更新唤醒睡眠中的电脑。
- `StartWhenAvailable` 用来在电脑从睡眠恢复或错过触发后尽快补跑。
- 不要勾选“仅在有网络时启动”；网络临时失败由主脚本记录并在下个小时重试。

### 7.5 权限和失败处理

目标是普通用户安装。如果机器策略禁止普通用户创建计划任务：

- 不要静默失败。
- 显示实际错误。
- 告诉用户程序文件已经复制到哪里。
- 给出手动运行主脚本的完整命令。
- 不要自动要求或保存管理员密码。

## 8. 卸载脚本要求：`uninstall.ps1`

默认卸载应：

1. 删除名称完全匹配 `Bing Daily Wallpaper` 的计划任务。
2. 删除 `%LOCALAPPDATA%\BingWallpaper` 中由本项目安装的程序文件。
3. 保留已下载图片、`.last_url` 和日志。
4. 保留当前正在显示的壁纸，不主动切回旧壁纸。
5. 多次执行也不报致命错误，即幂等。

可提供明确参数：

```powershell
.\uninstall.ps1 -RemoveDownloadedImages
```

只有用户显式提供该参数时，才允许删除 `<系统图片目录>\BingWallpapers`。删除前必须再次解析并验证目标是“系统图片目录的直接子目录 BingWallpapers”，不能在路径为空、解析失败、指向磁盘根目录或指向图片目录本身时递归删除。

删除完成后说明删除了什么、保留了什么。卸载不应删除仓库源文件。

## 9. Windows README 要求

`windows/README.md` 至少包含：

1. 功能简介和支持系统。
2. 每个文件的用途。
3. 安装方法。
4. 如果脚本执行策略阻止双击，如何从 PowerShell 安全运行安装命令。
5. 立即手动运行的方法。
6. 查看计划任务状态的方法。
7. 查看日志的方法。
8. 修改 Bing 地区的方法。
9. 更新脚本后重新安装的方法。
10. 卸载方法，以及默认保留图片的说明。
11. 多显示器行为。
12. Windows 11 虚拟桌面实测结果和已知限制。
13. 常见故障：网络失败、企业壁纸策略、任务未运行、图片目录迁移、主题/Spotlight 抢占壁纸。

建议安装命令写成用户可以直接复制的形式，例如先进入 `windows` 目录，再执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

不要要求用户关闭系统安全软件，也不要建议永久放宽全局执行策略。

## 10. 错误处理与退出码

建议约定：

```text
0 = 成功；包括无需下载、壁纸原本就正确、另一个实例正在运行
1 = 运行失败；包括网络、下载、验证、COM 设置或设置后校验失败
2 = 配置/参数/平台不支持
```

不论退出码如何，主脚本都必须释放 Mutex、关闭文件/图片对象并删除自己的临时下载文件。

计划任务应保留主脚本的退出码，方便在任务计划程序的“上次运行结果”中判断状态。

## 11. 安全与稳健性要求

必须遵守：

- 不使用 `Invoke-Expression`。
- 不下载并执行远程脚本或可执行文件。
- 不写入 HKLM。
- 不永久修改 PowerShell 执行策略。
- 不修改 Windows Defender、防火墙或 UAC。
- 不使用明文凭据。
- 不申请 SYSTEM 权限。
- 不随意杀死 Explorer。
- 不修改未公开的虚拟桌面注册表数据。
- 不对未经精确验证的宽泛目录执行递归删除。
- 所有网络内容先保存为数据文件并验证，不作为代码执行。
- Bing 请求失败时保留昨天的有效壁纸，而不是设置空白或损坏文件。

## 12. 必须执行的实机验收测试

AI/开发者在 Windows 机器上完成代码后，必须实际执行以下测试，并在最终报告里逐项给出结果。仅做静态检查不算完成。

### 12.1 基础安装

1. 在非管理员 Windows PowerShell 5.1 中运行 `install.ps1`。
2. 确认 `%LOCALAPPDATA%\BingWallpaper\bing_wallpaper.ps1` 存在。
3. 确认计划任务存在、运行身份是当前用户、权限级别为最低权限。
4. 确认首次安装后立即生成当天图片和日志。
5. 确认任务“上次运行结果”为成功。

### 12.2 下载和文件验证

1. 删除当天本地图片但保留 `.last_url`，手动运行；应重新下载。
2. 把当天图片替换成文本文件，手动运行；应识别损坏并重新下载。
3. 临时断网后运行；应返回失败、写日志、保留已有有效图片和 `.last_url`。
4. 恢复网络后运行；应自动恢复成功。
5. 检查失败路径没有遗留 `.tmp` 文件。

### 12.3 重复运行与自动恢复

1. 连续运行两次；第二次不应重复下载。
2. 第二次仍要验证当前显示器壁纸。
3. 手动把桌面换成另一张图片，再运行脚本；应恢复为当天 Bing 图片。
4. 验证 `.last_url` 只在完整成功后更新。
5. 同时手动启动两个实例；第二个应安全退出，不损坏文件。

### 12.4 多显示器

如果测试机有两个或更多物理显示器：

1. 先给不同显示器设置不同壁纸。
2. 运行脚本。
3. 确认所有显示器都使用同一张当天图片。
4. 检查日志记录的显示器数量与系统一致。
5. 断开一个显示器再运行，不能因为历史显示器 ID 失败。
6. 重新连接显示器并再次运行，全部恢复一致。

如果测试机只有一个显示器，必须在最终报告明确写“多显示器尚未实机验证”，不能声称已验证。

### 12.5 睡眠、登录和计划任务

1. 手动启动计划任务，确认能修改当前桌面。
2. 注销再登录，确认登录触发执行。
3. 检查触发器确实每小时无限重复，没有十年或若干天的到期时间。
4. 让机器睡眠并错过一次计划时间，唤醒后检查 `StartWhenAvailable` 的表现并记录。
5. 确认脚本运行超过一个小时的极端情况下不会叠加新实例。

### 12.6 Windows 11 虚拟桌面

在 Windows 11 上按第 3.3 节执行三个虚拟桌面测试，把结果写进 `windows/README.md`。如果只能影响当前虚拟桌面，必须明确说明；不要用未经授权的内部接口掩盖问题。

### 12.7 卸载

1. 运行默认卸载，确认任务和安装目录被删除。
2. 确认图片、日志和当前壁纸被保留。
3. 再运行一次卸载，确认不会因对象不存在而失败。
4. 重新安装后，使用 `-RemoveDownloadedImages` 卸载，确认只删除精确的 BingWallpapers 目录，没有影响系统图片目录中的其他内容。

## 13. 可选自动化测试

如增加 `windows/test.ps1`，测试应尽量避免依赖外网和当天实际图片内容。可以通过临时目录和可注入参数测试：

- URL 组合。
- 状态文件读写。
- JPEG 头和损坏文件识别。
- 过期文件筛选。
- 路径规范化和不区分大小写比较。
- 参数验证。
- 下载失败时不替换正式文件。

不要让自动化测试删除或覆盖用户真实壁纸。真实 COM 设置和多显示器测试应由明确的集成测试步骤执行。

## 14. 建议实施顺序

1. 阅读当前 macOS `README.md` 和 `bing_wallpaper.sh`，确认已有行为。
2. 实现 Windows 主脚本中的目录、日志、API 请求、下载和 JPEG 验证。
3. 实现完整且正确的 `IDesktopWallpaper` C# interop。
4. 完成单显示器设置与设置后验证。
5. 加入并发控制、原子状态写入和过期图片清理。
6. 实现幂等安装脚本和无限每小时登录触发任务。
7. 实现保守的卸载脚本。
8. 在真实 Windows PowerShell 5.1 中安装并完成验收测试。
9. 根据实测修复引号、COM、任务注册和路径问题。
10. 最后编写 Windows README，并给根 README 增加入口。

## 15. 完成定义

只有同时满足以下条件，才可以报告任务完成：

- `windows` 目录中的必需文件全部存在。
- 主脚本在 Windows PowerShell 5.1 中语法通过并实际运行成功。
- 当天 UHD 图片下载、验证、设置、逐显示器复核全部成功。
- 安装脚本以当前用户注册正确的登录后每小时任务。
- 计划任务实际运行成功，不只是注册成功。
- 重复运行不重复下载，手动替换壁纸后能恢复。
- 网络失败和损坏文件场景不会破坏现有状态。
- 卸载行为符合保留和显式删除规则。
- `windows/README.md` 记录真实测试结论，尤其是多显示器和 Windows 11 虚拟桌面结论。
- 没有破坏现有 macOS 文件和用法。

## 16. 最终报告格式

完成后请给用户一个简洁但具体的报告，包含：

1. 创建或修改了哪些文件。
2. 安装目录、图片目录、日志目录和计划任务名称。
3. Windows 版本、PowerShell 版本和账户权限级别。
4. 单显示器/多显示器测试结果。
5. Windows 11 虚拟桌面测试结果。
6. 睡眠恢复和登录触发测试结果。
7. 网络失败、损坏图片、重复运行和卸载测试结果。
8. 尚未验证或仍存在的限制。
9. 用户之后最常用的安装、立即运行、查看日志和卸载命令。

不要只说“代码已完成”或“理论上可以”。必须区分“已在当前 Windows 机器实测通过”和“因硬件/环境不足尚未验证”。
