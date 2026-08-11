[CmdletBinding()]
param(
    [string]$Market = 'zh-CN',
    [int]$RetentionDays = 7,
    [Parameter(DontShow = $true)]
    [string]$MetadataEndpoint = 'https://www.bing.com/HPImageArchive.aspx'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFile = $null

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)

    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        if ([string]::IsNullOrWhiteSpace($script:LogFile)) {
            throw '日志路径尚未初始化。'
        }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
    catch {
        Write-Warning ("无法写入日志：{0}`n{1}" -f $_.Exception.Message, $line)
    }
}

function Test-MarketValue {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -cmatch '^[a-z]{2}-[A-Z]{2}$'
}

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    try {
        return [string]::Equals((Get-NormalizedPath $Left), (Get-NormalizedPath $Right), [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Test-JpegFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$MinimumBytes = 10240
    )

    if (-not [IO.File]::Exists($Path)) {
        return $false
    }

    $stream = $null
    $image = $null
    try {
        $file = Get-Item -LiteralPath $Path -Force
        if ($file.Length -lt $MinimumBytes) {
            return $false
        }

        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.ReadByte() -ne 0xFF -or $stream.ReadByte() -ne 0xD8 -or $stream.ReadByte() -ne 0xFF) {
            return $false
        }
        $stream.Dispose()
        $stream = $null

        Add-Type -AssemblyName System.Drawing
        $image = [Drawing.Image]::FromFile($Path)
        if ($image.Width -le 0 -or $image.Height -le 0) {
            return $false
        }
        return $image.RawFormat.Guid -eq [Drawing.Imaging.ImageFormat]::Jpeg.Guid
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $image) {
            $image.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Move-FileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    # 临时文件与目标文件位于同一目录（同一卷）；让文件系统执行移动/替换。
    # 不使用 File.Replace(..., $null)：Windows PowerShell 5.1 会把空备份路径
    # 错误绑定成空字符串，并抛出“The path is not of a legal form”。
    Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
}

function Write-StateAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $directory = [IO.Path]::GetDirectoryName($Path)
    $temporaryPath = Join-Path $directory ('.last_url.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($temporaryPath, ($Value.Trim() + [Environment]::NewLine), $utf8WithoutBom)
        Move-FileAtomically -Source $temporaryPath -Destination $Path
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-BingImageUrl {
    param([Parameter(Mandatory = $true)]$Metadata)

    if ($null -eq $Metadata.images -or @($Metadata.images).Count -lt 1) {
        throw 'Bing 元数据中的 images 为空。'
    }
    $urlBase = [string]$Metadata.images[0].urlbase
    if ([string]::IsNullOrWhiteSpace($urlBase) -or -not $urlBase.StartsWith('/')) {
        throw 'Bing 元数据中的 urlbase 缺失或格式无效。'
    }
    return 'https://www.bing.com{0}_UHD.jpg' -f $urlBase
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$MaximumAttempts = 3
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            return & $Operation
        }
        catch {
            $lastError = $_
            Write-Log ("{0}（第 {1}/{2} 次）：{3}" -f $Description, $attempt, $MaximumAttempts, $_.Exception.Message)
            if ($attempt -lt $MaximumAttempts) {
                Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))
            }
        }
    }
    throw $lastError
}

function Install-DownloadedImage {
    param(
        [Parameter(Mandatory = $true)][string]$TemporaryPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (-not (Test-JpegFile -Path $TemporaryPath)) {
        throw '下载文件未通过 JPEG 格式、大小或解码验证。'
    }
    Move-FileAtomically -Source $TemporaryPath -Destination $DestinationPath
}

function Initialize-DesktopWallpaperInterop {
    if ('BingWallpaper.Interop.DesktopWallpaperClient' -as [type]) {
        return
    }

    $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace BingWallpaper.Interop
{
    public enum DesktopWallpaperPosition
    {
        Center = 0,
        Tile = 1,
        Stretch = 2,
        Fit = 3,
        Fill = 4,
        Span = 5
    }

    [Flags]
    internal enum DesktopSlideshowOptions
    {
        ShuffleImages = 0x01
    }

    internal enum DesktopSlideshowDirection
    {
        Forward = 0,
        Backward = 1
    }

    [Flags]
    internal enum DesktopSlideshowState
    {
        Enabled = 0x01,
        Slideshow = 0x02,
        DisabledByRemoteSession = 0x04
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [ComImport]
    [Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDesktopWallpaper
    {
        [PreserveSig]
        int SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID,
                         [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);

        [PreserveSig]
        int GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, out IntPtr wallpaper);

        [PreserveSig]
        int GetMonitorDevicePathAt(uint monitorIndex, out IntPtr monitorID);

        [PreserveSig]
        int GetMonitorDevicePathCount(out uint count);

        [PreserveSig]
        int GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID, out NativeRect displayRect);

        [PreserveSig]
        int SetBackgroundColor(uint color);

        [PreserveSig]
        int GetBackgroundColor(out uint color);

        [PreserveSig]
        int SetPosition(DesktopWallpaperPosition position);

        [PreserveSig]
        int GetPosition(out DesktopWallpaperPosition position);

        [PreserveSig]
        int SetSlideshow(IntPtr items);

        [PreserveSig]
        int GetSlideshow(out IntPtr items);

        [PreserveSig]
        int SetSlideshowOptions(DesktopSlideshowOptions options, uint slideshowTick);

        [PreserveSig]
        int GetSlideshowOptions(out DesktopSlideshowOptions options, out uint slideshowTick);

        [PreserveSig]
        int AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorID,
                             DesktopSlideshowDirection direction);

        [PreserveSig]
        int GetStatus(out DesktopSlideshowState state);

        [PreserveSig]
        int Enable([MarshalAs(UnmanagedType.Bool)] bool enable);
    }

    [ComImport]
    [Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD")]
    internal class DesktopWallpaperClass
    {
    }

    public sealed class MonitorWallpaper
    {
        public string DevicePath { get; private set; }
        public string WallpaperPath { get; private set; }

        internal MonitorWallpaper(string devicePath, string wallpaperPath)
        {
            DevicePath = devicePath;
            WallpaperPath = wallpaperPath;
        }
    }

    public sealed class DesktopWallpaperClient : IDisposable
    {
        private IDesktopWallpaper wallpaper;

        public DesktopWallpaperClient()
        {
            wallpaper = (IDesktopWallpaper)new DesktopWallpaperClass();
        }

        private static void ThrowIfFailed(int result)
        {
            if (result < 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }
        }

        private static string TakeString(IntPtr value)
        {
            if (value == IntPtr.Zero)
            {
                return String.Empty;
            }
            try
            {
                return Marshal.PtrToStringUni(value) ?? String.Empty;
            }
            finally
            {
                Marshal.FreeCoTaskMem(value);
            }
        }

        public void SetAll(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
            {
                throw new ArgumentException("Wallpaper path must not be empty.", "path");
            }
            ThrowIfFailed(wallpaper.Enable(true));
            ThrowIfFailed(wallpaper.SetPosition(DesktopWallpaperPosition.Fill));
            ThrowIfFailed(wallpaper.SetWallpaper(null, path));
        }

        public DesktopWallpaperPosition GetPosition()
        {
            DesktopWallpaperPosition position;
            ThrowIfFailed(wallpaper.GetPosition(out position));
            return position;
        }

        public MonitorWallpaper[] GetMonitorWallpapers()
        {
            uint count;
            ThrowIfFailed(wallpaper.GetMonitorDevicePathCount(out count));
            List<MonitorWallpaper> result = new List<MonitorWallpaper>();
            for (uint index = 0; index < count; index++)
            {
                IntPtr monitorValue;
                ThrowIfFailed(wallpaper.GetMonitorDevicePathAt(index, out monitorValue));
                string monitorID = TakeString(monitorValue);

                IntPtr wallpaperValue;
                ThrowIfFailed(wallpaper.GetWallpaper(monitorID, out wallpaperValue));
                result.Add(new MonitorWallpaper(monitorID, TakeString(wallpaperValue)));
            }
            return result.ToArray();
        }

        public void Dispose()
        {
            if (wallpaper != null)
            {
                Marshal.FinalReleaseComObject(wallpaper);
                wallpaper = null;
            }
            GC.SuppressFinalize(this);
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp
}

function Get-WallpaperVerification {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$ExpectedPath
    )

    $monitors = @($Client.GetMonitorWallpapers())
    $details = New-Object Collections.Generic.List[string]
    $allMatch = $monitors.Count -gt 0
    foreach ($monitor in $monitors) {
        $actual = [string]$monitor.WallpaperPath
        $matches = Test-PathEqual -Left $actual -Right $ExpectedPath
        if (-not $matches) {
            $allMatch = $false
        }
        $details.Add(('显示器 {0}：{1}' -f $monitor.DevicePath, $(if ([string]::IsNullOrWhiteSpace($actual)) { '<空>' } else { $actual })))
    }

    [pscustomobject]@{
        AllMatch = $allMatch
        Count = $monitors.Count
        Details = $details.ToArray()
    }
}

function Remove-ExpiredWallpapers {
    param(
        [Parameter(Mandatory = $true)][string]$SaveDirectory,
        [Parameter(Mandatory = $true)][string]$CurrentImage,
        [Parameter(Mandatory = $true)][int]$Days
    )

    $cutoff = (Get-Date).AddDays(-$Days)
    $normalizedDirectory = Get-NormalizedPath $SaveDirectory
    $deleted = New-Object Collections.Generic.List[string]

    foreach ($file in @(Get-ChildItem -LiteralPath $SaveDirectory -Force -File -ErrorAction Stop)) {
        if ($file.Name -cnotmatch '^bing_[^\\/]+\.jpg$') {
            continue
        }
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            continue
        }
        if (-not [string]::Equals((Get-NormalizedPath $file.DirectoryName), $normalizedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ((Test-PathEqual -Left $file.FullName -Right $CurrentImage) -or $file.LastWriteTime -ge $cutoff) {
            continue
        }
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $deleted.Add($file.FullName)
        }
        catch {
            Write-Log ("清理旧图片失败：{0}；{1}" -f $file.FullName, $_.Exception.Message)
        }
    }

    if ($deleted.Count -gt 0) {
        Write-Log ("已删除 {0} 张过期图片：{1}" -f $deleted.Count, ($deleted -join '；'))
    }
    else {
        Write-Log '没有需要删除的过期图片。'
    }
}

function Invoke-BingWallpaper {
    $mutex = $null
    $mutexAcquired = $false
    $temporaryDownload = $null
    $client = $null
    $runStarted = $false

    try {
        if (-not (Test-MarketValue $Market)) {
            [Console]::Error.WriteLine('Market 必须是 zh-CN、en-US、ja-JP 这类大小写严格的地区代码。')
            return 2
        }
        if ($RetentionDays -lt 1 -or $RetentionDays -gt 365) {
            [Console]::Error.WriteLine('RetentionDays 必须是 1 到 365 之间的整数。')
            return 2
        }
        if ($env:OS -ne 'Windows_NT' -or [Environment]::OSVersion.Version.Major -lt 10 -or -not [Environment]::Is64BitOperatingSystem) {
            [Console]::Error.WriteLine('此脚本仅支持 64 位 Windows 10 或 Windows 11。')
            return 2
        }

        $picturesDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)
        if ([string]::IsNullOrWhiteSpace($picturesDirectory)) {
            throw '无法解析当前用户的系统“图片”目录。'
        }
        $saveDirectory = Join-Path $picturesDirectory 'BingWallpapers'
        [IO.Directory]::CreateDirectory($saveDirectory) | Out-Null
        $script:LogFile = Join-Path $saveDirectory 'bing_wallpaper.log'
        $lastUrlFile = Join-Path $saveDirectory '.last_url'
        $runStarted = $true
        Write-Log ("脚本开始：地区={0}，保留天数={1}" -f $Market, $RetentionDays)

        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $mutex = New-Object Threading.Mutex($false, ('Local\BingDailyWallpaper_{0}' -f $sid))
        try {
            $mutexAcquired = $mutex.WaitOne(0, $false)
        }
        catch [Threading.AbandonedMutexException] {
            $mutexAcquired = $true
        }
        if (-not $mutexAcquired) {
            Write-Log '检测到另一个实例正在运行，本次安全退出。'
            return 0
        }

        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $encodedMarket = [Uri]::EscapeDataString($Market)
        $endpointUri = $null
        if (-not [Uri]::TryCreate($MetadataEndpoint, [UriKind]::Absolute, [ref]$endpointUri) -or
            ($endpointUri.Scheme -ne 'https' -and $endpointUri.Scheme -ne 'http')) {
            Write-Log 'MetadataEndpoint 必须是绝对 HTTP 或 HTTPS URL。'
            return 2
        }
        $separator = $(if ($MetadataEndpoint.Contains('?')) { '&' } else { '?' })
        $metadataUrl = '{0}{1}format=js&idx=0&n=1&mkt={2}' -f $MetadataEndpoint, $separator, $encodedMarket
        try {
            $metadata = Invoke-WithRetry -Description '获取 Bing 元数据失败' -Operation {
                Invoke-RestMethod -Uri $metadataUrl -Method Get -TimeoutSec 60
            }
            $imageUrl = Get-BingImageUrl -Metadata $metadata
        }
        catch {
            Write-Log ("获取或解析 Bing 每日图片信息失败：{0}" -f $_.Exception.Message)
            return 1
        }

        $today = Get-Date -Format 'yyyy-MM-dd'
        $imagePath = Join-Path $saveDirectory ('bing_{0}.jpg' -f $today)
        $lastUrl = ''
        if ([IO.File]::Exists($lastUrlFile)) {
            try {
                $lastUrl = [IO.File]::ReadAllText($lastUrlFile).Trim()
            }
            catch {
                Write-Log ("读取状态文件失败，将重新下载并验证：{0}" -f $_.Exception.Message)
            }
        }

        $imageValid = Test-JpegFile -Path $imagePath
        $downloaded = $false
        if ($imageUrl -ne $lastUrl -or -not $imageValid) {
            $temporaryDownload = Join-Path $saveDirectory ('.bing_wallpaper.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
            Write-Log ("开始下载 UHD 图片：{0}" -f $imageUrl)
            try {
                Invoke-WithRetry -Description '下载图片失败' -Operation {
                    Invoke-WebRequest -Uri $imageUrl -Method Get -UseBasicParsing -TimeoutSec 120 -OutFile $temporaryDownload | Out-Null
                } | Out-Null
                Install-DownloadedImage -TemporaryPath $temporaryDownload -DestinationPath $imagePath
                $temporaryDownload = $null
                $downloaded = $true
                Write-Log ("下载成功并通过 JPEG 验证：{0}" -f $imagePath)
            }
            catch {
                Write-Log ("下载文件验证或替换失败：{0}；{1}" -f $imageUrl, $_.Exception.Message)
                return 1
            }
        }

        if (-not (Test-JpegFile -Path $imagePath)) {
            Write-Log ("当日图片不存在或验证失败：{0}" -f $imagePath)
            return 1
        }

        try {
            Initialize-DesktopWallpaperInterop
            $client = New-Object BingWallpaper.Interop.DesktopWallpaperClient
            $initialVerification = Get-WallpaperVerification -Client $client -ExpectedPath $imagePath
            $positionIsFill = [int]$client.GetPosition() -eq 4
            $wasAlreadyCorrect = $initialVerification.AllMatch -and $positionIsFill

            if (-not $wasAlreadyCorrect) {
                $client.SetAll((Get-NormalizedPath $imagePath))
                $verified = $false
                $finalVerification = $initialVerification
                for ($attempt = 1; $attempt -le 10; $attempt++) {
                    Start-Sleep -Milliseconds 500
                    $finalVerification = Get-WallpaperVerification -Client $client -ExpectedPath $imagePath
                    if ($finalVerification.AllMatch -and [int]$client.GetPosition() -eq 4) {
                        $verified = $true
                        break
                    }
                }
                if (-not $verified) {
                    Write-Log ("壁纸设置后验证失败；枚举到 {0} 个显示器；{1}" -f $finalVerification.Count, ($finalVerification.Details -join '；'))
                    return 1
                }
            }
            elseif ($initialVerification.Count -lt 1) {
                Write-Log '未枚举到任何物理显示器，无法确认壁纸设置结果。'
                return 1
            }

            Write-StateAtomically -Path $lastUrlFile -Value $imageUrl
            if ($wasAlreadyCorrect) {
                Write-Log ("所有显示器已使用当日图片：{0}（共 {1} 个显示器）" -f $imagePath, $initialVerification.Count)
            }
            elseif ($downloaded) {
                Write-Log ("已下载 UHD 图片并应用到所有显示器：{0}" -f $imagePath)
            }
            else {
                Write-Log ("检测到壁纸被替换或显示方式变化，已恢复到所有显示器：{0}" -f $imagePath)
            }
        }
        catch {
            Write-Log ("设置或验证壁纸失败：{0}" -f $_.Exception.ToString())
            return 1
        }
        finally {
            if ($null -ne $client) {
                $client.Dispose()
                $client = $null
            }
        }

        try {
            Remove-ExpiredWallpapers -SaveDirectory $saveDirectory -CurrentImage $imagePath -Days $RetentionDays
        }
        catch {
            Write-Log ("清理过期图片时发生错误（不影响本次壁纸设置）：{0}" -f $_.Exception.Message)
        }
        return 0
    }
    catch {
        if ($runStarted) {
            Write-Log ("脚本运行失败：{0}" -f $_.Exception.ToString())
        }
        else {
            [Console]::Error.WriteLine($_.Exception.ToString())
        }
        return 1
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($temporaryDownload) -and [IO.File]::Exists($temporaryDownload)) {
            Remove-Item -LiteralPath $temporaryDownload -Force -ErrorAction SilentlyContinue
        }
        if ($mutexAcquired -and $null -ne $mutex) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
        if ($runStarted) {
            Write-Log '脚本结束。'
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-BingWallpaper)
}
