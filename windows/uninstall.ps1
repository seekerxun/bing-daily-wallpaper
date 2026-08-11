[CmdletBinding()]
param(
    [switch]$RemoveDownloadedImages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'Bing Daily Wallpaper'
$localApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$installDirectory = Join-Path $localApplicationData 'BingWallpaper'
$picturesDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)
$wallpaperDirectory = Join-Path $picturesDirectory 'BingWallpapers'
$taskService = $null
$rootFolder = $null
$failed = $false

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

try {
    try {
        $taskService = New-Object -ComObject 'Schedule.Service'
        $taskService.Connect()
        $rootFolder = $taskService.GetFolder('\')
        try {
            $rootFolder.DeleteTask($taskName, 0)
            Write-Host "已删除计划任务：$taskName"
        }
        catch {
            # Windows PowerShell 5.1 可能把任务计划程序的 0x80070002
            # 包装成 FileNotFoundException，而不是 COMException。
            if ($_.Exception.HResult -eq -2147024894) {
                Write-Host "计划任务不存在，无需删除：$taskName"
            }
            else {
                throw
            }
        }
    }
    catch {
        $failed = $true
        Write-Warning ("删除计划任务失败：{0}" -f $_.Exception.Message)
    }

    try {
        $normalizedLocalAppData = Get-NormalizedPath $localApplicationData
        $normalizedInstallDirectory = Get-NormalizedPath $installDirectory
        $installParent = Get-NormalizedPath ([IO.Directory]::GetParent($normalizedInstallDirectory).FullName)
        if (-not [string]::Equals($installParent, $normalizedLocalAppData, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([IO.Path]::GetFileName($normalizedInstallDirectory), 'BingWallpaper', [StringComparison]::OrdinalIgnoreCase)) {
            throw "安装目录安全校验失败：$installDirectory"
        }
        if ([IO.Directory]::Exists($installDirectory)) {
            $installItem = Get-Item -LiteralPath $installDirectory -Force
            if (($installItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "拒绝递归删除重解析点：$installDirectory"
            }
            Remove-Item -LiteralPath $installDirectory -Recurse -Force
            Write-Host "已删除程序目录：$installDirectory"
        }
        else {
            Write-Host "程序目录不存在，无需删除：$installDirectory"
        }
    }
    catch {
        $failed = $true
        Write-Warning ("删除程序目录失败：{0}" -f $_.Exception.Message)
    }

    if ($RemoveDownloadedImages) {
        try {
            if ([string]::IsNullOrWhiteSpace($picturesDirectory)) {
                throw '无法解析系统“图片”目录。'
            }
            $normalizedPictures = Get-NormalizedPath $picturesDirectory
            $normalizedWallpaperDirectory = Get-NormalizedPath $wallpaperDirectory
            $wallpaperParent = Get-NormalizedPath ([IO.Directory]::GetParent($normalizedWallpaperDirectory).FullName)
            if ([string]::IsNullOrWhiteSpace($normalizedWallpaperDirectory) -or
                [string]::Equals($normalizedWallpaperDirectory, [IO.Path]::GetPathRoot($normalizedWallpaperDirectory), [StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals($normalizedWallpaperDirectory, $normalizedPictures, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($wallpaperParent, $normalizedPictures, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([IO.Path]::GetFileName($normalizedWallpaperDirectory), 'BingWallpapers', [StringComparison]::OrdinalIgnoreCase)) {
                throw "下载目录安全校验失败：$wallpaperDirectory"
            }
            if ([IO.Directory]::Exists($wallpaperDirectory)) {
                $wallpaperItem = Get-Item -LiteralPath $wallpaperDirectory -Force
                if (($wallpaperItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "拒绝递归删除重解析点：$wallpaperDirectory"
                }
                Remove-Item -LiteralPath $wallpaperDirectory -Recurse -Force
                Write-Host "已删除下载图片、状态和日志：$wallpaperDirectory"
            }
            else {
                Write-Host "下载目录不存在，无需删除：$wallpaperDirectory"
            }
        }
        catch {
            $failed = $true
            Write-Warning ("删除下载目录失败：{0}" -f $_.Exception.Message)
        }
    }
    else {
        Write-Host "已保留下载图片、状态和日志：$wallpaperDirectory"
    }

    Write-Host '当前桌面壁纸保持不变。'
    if ($failed) { exit 1 }
    exit 0
}
finally {
    foreach ($comObject in @($rootFolder, $taskService)) {
        if ($null -ne $comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
        }
    }
}
