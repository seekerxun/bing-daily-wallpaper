[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'Bing Daily Wallpaper'
$sourceScript = Join-Path $PSScriptRoot 'bing_wallpaper.ps1'
$installDirectory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'BingWallpaper'
$installedScript = Join-Path $installDirectory 'bing_wallpaper.ps1'
$picturesDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)
$wallpaperDirectory = Join-Path $picturesDirectory 'BingWallpapers'
$logFile = Join-Path $wallpaperDirectory 'bing_wallpaper.log'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskService = $null
$rootFolder = $null
$definition = $null
$registeredTask = $null

try {
    if ($env:OS -ne 'Windows_NT' -or [Environment]::OSVersion.Version.Major -lt 10 -or -not [Environment]::Is64BitOperatingSystem) {
        throw '安装程序仅支持 64 位 Windows 10 或 Windows 11。'
    }
    if (-not [IO.File]::Exists($sourceScript)) {
        throw "缺少主程序：$sourceScript"
    }
    if ([string]::IsNullOrWhiteSpace($picturesDirectory)) {
        throw '无法解析当前用户的系统“图片”目录。'
    }
    if (-not [IO.File]::Exists($powerShellPath)) {
        throw "找不到 Windows PowerShell 5.1：$powerShellPath"
    }

    [IO.Directory]::CreateDirectory($installDirectory) | Out-Null
    Copy-Item -LiteralPath $sourceScript -Destination $installedScript -Force

    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskService = New-Object -ComObject 'Schedule.Service'
    $taskService.Connect()
    $rootFolder = $taskService.GetFolder('\')
    $definition = $taskService.NewTask(0)

    $definition.RegistrationInfo.Description = '登录后及登录期间每小时检查并设置 Bing 每日 UHD 壁纸。'
    $definition.RegistrationInfo.Author = $currentUser

    $definition.Principal.UserId = $currentUser
    $definition.Principal.LogonType = 3
    $definition.Principal.RunLevel = 0

    $trigger = $definition.Triggers.Create(9)
    $trigger.Id = 'AtLogonHourly'
    $trigger.UserId = $currentUser
    $trigger.Enabled = $true
    $trigger.Repetition.Interval = 'PT1H'
    $trigger.Repetition.StopAtDurationEnd = $false

    $action = $definition.Actions.Create(0)
    $action.Path = $powerShellPath
    $action.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $installedScript
    $action.WorkingDirectory = $installDirectory

    $definition.Settings.Enabled = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.WakeToRun = $false
    $definition.Settings.RunOnlyIfNetworkAvailable = $false
    $definition.Settings.MultipleInstances = 2
    $definition.Settings.ExecutionTimeLimit = 'PT10M'
    $definition.Settings.AllowHardTerminate = $true

    $registeredTask = $rootFolder.RegisterTaskDefinition($taskName, $definition, 6, $currentUser, $null, 3, $null)

    Write-Host '计划任务注册成功，正在执行首次更新……'
    & $powerShellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installedScript
    $firstRunExitCode = $LASTEXITCODE

    Write-Host ''
    Write-Host '安装完成。'
    Write-Host ("程序位置：{0}" -f $installedScript)
    Write-Host ("图片目录：{0}" -f $wallpaperDirectory)
    Write-Host ("日志位置：{0}" -f $logFile)
    Write-Host ("计划任务：{0}" -f $taskName)
    Write-Host ("首次运行退出码：{0}" -f $firstRunExitCode)

    if ($firstRunExitCode -ne 0) {
        Write-Warning "计划任务已安装，但首次壁纸更新失败。请检查日志：$logFile"
        exit 1
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine(("安装失败：{0}" -f $_.Exception.ToString()))
    if ([IO.File]::Exists($installedScript)) {
        Write-Host ("程序文件已复制到：{0}" -f $installedScript)
        Write-Host ("可手动运行：& '{0}' -NoLogo -NoProfile -ExecutionPolicy Bypass -File '{1}'" -f $powerShellPath, $installedScript)
    }
    exit 1
}
finally {
    foreach ($comObject in @($registeredTask, $definition, $rootFolder, $taskService)) {
        if ($null -ne $comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
        }
    }
}
