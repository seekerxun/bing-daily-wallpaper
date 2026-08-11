[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mainScript = Join-Path $PSScriptRoot 'bing_wallpaper.ps1'
$scripts = @(
    $mainScript,
    (Join-Path $PSScriptRoot 'install.ps1'),
    (Join-Path $PSScriptRoot 'uninstall.ps1'),
    $PSCommandPath
)
$failures = New-Object Collections.Generic.List[string]
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('BingWallpaperTests_{0}' -f [Guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

try {
    foreach ($scriptPath in $scripts) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) ("PowerShell 语法错误：{0}；{1}" -f $scriptPath, (($errors | ForEach-Object Message) -join '；'))
    }

    . $mainScript
    [IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null

    Assert-True (Test-MarketValue 'zh-CN') '合法地区代码 zh-CN 未通过校验。'
    Assert-True (-not (Test-MarketValue 'ZH-cn')) '非法地区代码 ZH-cn 被接受。'

    $metadata = [pscustomobject]@{ images = @([pscustomobject]@{ urlbase = '/th?id=OHR.UnitTest' }) }
    Assert-True ((Get-BingImageUrl $metadata) -eq 'https://www.bing.com/th?id=OHR.UnitTest_UHD.jpg') 'UHD URL 组合错误。'

    $casePath = Join-Path $temporaryDirectory 'Example.jpg'
    Assert-True (Test-PathEqual $casePath $casePath.ToUpperInvariant()) 'Windows 路径比较未忽略大小写。'

    Add-Type -AssemblyName System.Drawing
    $validJpeg = Join-Path $temporaryDirectory 'valid.jpg'
    $bitmap = New-Object Drawing.Bitmap(160, 90)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.Clear([Drawing.Color]::SteelBlue) } finally { $graphics.Dispose() }
        $bitmap.Save($validJpeg, [Drawing.Imaging.ImageFormat]::Jpeg)
    }
    finally {
        $bitmap.Dispose()
    }
    Assert-True (Test-JpegFile -Path $validJpeg -MinimumBytes 100) '有效 JPEG 未通过校验。'

    $invalidJpeg = Join-Path $temporaryDirectory 'invalid.jpg'
    [IO.File]::WriteAllText($invalidJpeg, 'not a jpeg')
    Assert-True (-not (Test-JpegFile -Path $invalidJpeg -MinimumBytes 1)) '损坏 JPEG 被错误接受。'

    $destination = Join-Path $temporaryDirectory 'destination.jpg'
    [IO.File]::WriteAllText($destination, 'original')
    $downloadRejected = $false
    try { Install-DownloadedImage -TemporaryPath $invalidJpeg -DestinationPath $destination } catch { $downloadRejected = $true }
    Assert-True $downloadRejected '损坏下载没有被拒绝。'
    Assert-True ([IO.File]::ReadAllText($destination) -eq 'original') '损坏下载覆盖了原文件。'

    $statePath = Join-Path $temporaryDirectory '.last_url'
    Write-StateAtomically -Path $statePath -Value 'https://example.invalid/image.jpg'
    Assert-True ([IO.File]::ReadAllText($statePath).Trim() -eq 'https://example.invalid/image.jpg') '状态文件原子写入失败。'
    Assert-True (@(Get-ChildItem -LiteralPath $temporaryDirectory -Filter '.last_url.*.tmp' -Force).Count -eq 0) '状态临时文件未清理。'

    $script:LogFile = Join-Path $temporaryDirectory 'test.log'
    $currentImage = Join-Path $temporaryDirectory 'bing_current.jpg'
    $expiredImage = Join-Path $temporaryDirectory 'bing_expired.jpg'
    $unrelatedImage = Join-Path $temporaryDirectory 'user_photo.jpg'
    foreach ($path in @($currentImage, $expiredImage, $unrelatedImage)) { [IO.File]::WriteAllText($path, 'test') }
    (Get-Item -LiteralPath $currentImage).LastWriteTime = (Get-Date).AddDays(-30)
    (Get-Item -LiteralPath $expiredImage).LastWriteTime = (Get-Date).AddDays(-30)
    (Get-Item -LiteralPath $unrelatedImage).LastWriteTime = (Get-Date).AddDays(-30)
    Remove-ExpiredWallpapers -SaveDirectory $temporaryDirectory -CurrentImage $currentImage -Days 7
    Assert-True (Test-Path -LiteralPath $currentImage) '清理逻辑删除了当前图片。'
    Assert-True (-not (Test-Path -LiteralPath $expiredImage)) '清理逻辑未删除过期 Bing 图片。'
    Assert-True (Test-Path -LiteralPath $unrelatedImage) '清理逻辑删除了无关图片。'

    if ($failures.Count -gt 0) {
        foreach ($failure in $failures) { Write-Error $failure }
        exit 1
    }
    Write-Host '离线辅助测试全部通过。'
    exit 0
}
finally {
    if ([IO.Directory]::Exists($temporaryDirectory)) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
