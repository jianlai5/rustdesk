Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

function New-RoundedRectanglePath {
    param(
        [float]$Size,
        [float]$Radius
    )

    $diameter = $Radius * 2
    $max = $Size - 1
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $diameter, $diameter, 180, 90)
    $path.AddArc($max - $diameter, 0, $diameter, $diameter, 270, 90)
    $path.AddArc($max - $diameter, $max - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc(0, $max - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function New-SourceBitmap {
    param(
        [switch]$OpaqueBackground
    )

    $size = 1024
    $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $path = $null
    $brush = $null
    $pen = $null

    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $colorTop = [System.Drawing.Color]::FromArgb(255, 61, 140, 255)
        $colorBottom = [System.Drawing.Color]::FromArgb(255, 30, 108, 243)
        $graphics.Clear($(if ($OpaqueBackground) { $colorTop } else { [System.Drawing.Color]::Transparent }))
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush (
            [System.Drawing.PointF]::new(0, 0)
        ), (
            [System.Drawing.PointF]::new($size, $size)
        ), $colorTop, $colorBottom

        if ($OpaqueBackground) {
            $graphics.FillRectangle($brush, 0, 0, $size, $size)
        }
        else {
            $path = New-RoundedRectanglePath -Size $size -Radius 212
            $graphics.FillPath($brush, $path)
        }

        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 164
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Flat
        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Flat
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

        $graphics.DrawLine($pen, 320, 250, 512, 474)
        $graphics.DrawLine($pen, 704, 250, 512, 474)
        $graphics.DrawLine($pen, 512, 474, 512, 798)

        return $bitmap
    }
    catch {
        $bitmap.Dispose()
        throw
    }
    finally {
        if ($pen) {
            $pen.Dispose()
        }
        if ($brush) {
            $brush.Dispose()
        }
        if ($path) {
            $path.Dispose()
        }
        $graphics.Dispose()
    }
}

function Resize-Bitmap {
    param(
        [System.Drawing.Bitmap]$Source,
        [int]$Size
    )

    $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.DrawImage($Source, 0, 0, $Size, $Size)
        return $bitmap
    }
    catch {
        $bitmap.Dispose()
        throw
    }
    finally {
        $graphics.Dispose()
    }
}

function Get-PngBytes {
    param(
        [System.Drawing.Bitmap]$Bitmap
    )

    $stream = New-Object System.IO.MemoryStream
    try {
        $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

function Write-Ico {
    param(
        [hashtable]$Images,
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $sizes = $Images.Keys | Sort-Object
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $writer = New-Object System.IO.BinaryWriter $stream

    try {
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]$sizes.Count)

        $offset = 6 + (16 * $sizes.Count)
        foreach ($size in $sizes) {
            $data = [byte[]]$Images[$size]
            $entrySize = if ($size -ge 256) { 0 } else { $size }
            $writer.Write([byte]$entrySize)
            $writer.Write([byte]$entrySize)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]32)
            $writer.Write([UInt32]$data.Length)
            $writer.Write([UInt32]$offset)
            $offset += $data.Length
        }

        foreach ($size in $sizes) {
            $writer.Write([byte[]]$Images[$size])
        }
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Write-UInt32BigEndian {
    param(
        [System.IO.BinaryWriter]$Writer,
        [uint32]$Value
    )

    $bytes = [System.BitConverter]::GetBytes($Value)
    [Array]::Reverse($bytes)
    $Writer.Write($bytes)
}

function Write-Icns {
    param(
        [hashtable]$Images,
        [string]$Path
    )

    $iconTypes = [ordered]@{
        16   = "icp4"
        32   = "icp5"
        64   = "icp6"
        128  = "ic07"
        256  = "ic08"
        512  = "ic09"
        1024 = "ic10"
    }

    $chunks = New-Object System.Collections.Generic.List[byte[]]
    $totalLength = 8

    foreach ($entry in $iconTypes.GetEnumerator()) {
        $size = [int]$entry.Key
        if (-not $Images.ContainsKey($size)) {
            continue
        }

        $data = [byte[]]$Images[$size]
        $chunkLength = 8 + $data.Length
        $chunk = New-Object byte[] $chunkLength
        $typeBytes = [System.Text.Encoding]::ASCII.GetBytes($entry.Value)
        $lengthBytes = [System.BitConverter]::GetBytes([uint32]$chunkLength)
        [Array]::Reverse($lengthBytes)

        [Array]::Copy($typeBytes, 0, $chunk, 0, 4)
        [Array]::Copy($lengthBytes, 0, $chunk, 4, 4)
        [Array]::Copy($data, 0, $chunk, 8, $data.Length)

        $chunks.Add($chunk)
        $totalLength += $chunkLength
    }

    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $writer = New-Object System.IO.BinaryWriter $stream

    try {
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes("icns"))
        Write-UInt32BigEndian -Writer $writer -Value ([uint32]$totalLength)
        foreach ($chunk in $chunks) {
            $writer.Write($chunk)
        }
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

$root = Split-Path -Parent $PSScriptRoot
$source = New-SourceBitmap
$iosSource = New-SourceBitmap -OpaqueBackground

try {
    $pngCache = @{}
    foreach ($size in 16, 20, 29, 32, 40, 48, 58, 60, 64, 72, 76, 80, 87, 96, 120, 128, 144, 152, 167, 180, 192, 256, 512, 1024) {
        $bitmap = Resize-Bitmap -Source $source -Size $size
        try {
            $pngCache[$size] = Get-PngBytes -Bitmap $bitmap
        }
        finally {
            $bitmap.Dispose()
        }
    }

    $pngTargets = [ordered]@{
        (Join-Path $root "res\icon.png") = 1024
        (Join-Path $root "res\mac-icon.png") = 1024
        (Join-Path $root "res\32x32.png") = 32
        (Join-Path $root "res\64x64.png") = 64
        (Join-Path $root "res\128x128.png") = 128
        (Join-Path $root "res\128x128@2x.png") = 256
        (Join-Path $root "flutter\assets\icon.png") = 512
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-mdpi\ic_launcher.png") = 48
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-mdpi\ic_launcher_round.png") = 48
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-mdpi\ic_launcher_foreground.png") = 48
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-mdpi\ic_stat_logo.png") = 48
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-hdpi\ic_launcher.png") = 72
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-hdpi\ic_launcher_round.png") = 72
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-hdpi\ic_launcher_foreground.png") = 72
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-hdpi\ic_stat_logo.png") = 72
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xhdpi\ic_launcher.png") = 96
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xhdpi\ic_launcher_round.png") = 96
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xhdpi\ic_launcher_foreground.png") = 96
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xhdpi\ic_stat_logo.png") = 96
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xxhdpi\ic_launcher.png") = 144
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xxhdpi\ic_launcher_round.png") = 144
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xxhdpi\ic_launcher_foreground.png") = 144
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xxhdpi\ic_stat_logo.png") = 144
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png") = 192
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xxxhdpi\ic_launcher_round.png") = 192
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xxxhdpi\ic_launcher_foreground.png") = 192
        (Join-Path $root "flutter\android\app\src\main\res\mipmap-xxxhdpi\ic_stat_logo.png") = 192
    }

    foreach ($target in $pngTargets.GetEnumerator()) {
        [System.IO.File]::WriteAllBytes($target.Key, [byte[]]$pngCache[$target.Value])
    }

    $iosPngCache = @{}
    foreach ($size in 20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024) {
        $bitmap = Resize-Bitmap -Source $iosSource -Size $size
        try {
            $iosPngCache[$size] = Get-PngBytes -Bitmap $bitmap
        }
        finally {
            $bitmap.Dispose()
        }
    }

    $iosTargets = [ordered]@{
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-20x20@1x.png") = 20
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-20x20@2x.png") = 40
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-20x20@3x.png") = 60
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-29x29@1x.png") = 29
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-29x29@2x.png") = 58
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-29x29@3x.png") = 87
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-40x40@1x.png") = 40
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-40x40@2x.png") = 80
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-40x40@3x.png") = 120
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-60x60@2x.png") = 120
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-60x60@3x.png") = 180
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-76x76@1x.png") = 76
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-76x76@2x.png") = 152
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-83.5x83.5@2x.png") = 167
        (Join-Path $root "flutter\ios\Runner\Assets.xcassets\AppIcon.appiconset\Icon-App-1024x1024@1x.png") = 1024
    }

    foreach ($target in $iosTargets.GetEnumerator()) {
        [System.IO.File]::WriteAllBytes($target.Key, [byte[]]$iosPngCache[$target.Value])
    }

    $icoImages = @{
        16  = [byte[]]$pngCache[16]
        32  = [byte[]]$pngCache[32]
        48  = [byte[]]$pngCache[48]
        64  = [byte[]]$pngCache[64]
        128 = [byte[]]$pngCache[128]
        256 = [byte[]]$pngCache[256]
    }

    Write-Ico -Images $icoImages -Path (Join-Path $root "res\icon.ico")
    Write-Ico -Images $icoImages -Path (Join-Path $root "res\tray-icon.ico")
    Write-Ico -Images $icoImages -Path (Join-Path $root "flutter\windows\runner\resources\app_icon.ico")

    $icnsImages = @{
        16   = [byte[]]$pngCache[16]
        32   = [byte[]]$pngCache[32]
        64   = [byte[]]$pngCache[64]
        128  = [byte[]]$pngCache[128]
        256  = [byte[]]$pngCache[256]
        512  = [byte[]]$pngCache[512]
        1024 = [byte[]]$pngCache[1024]
    }

    Write-Icns -Images $icnsImages -Path (Join-Path $root "flutter\macos\Runner\AppIcon.icns")
}
finally {
    $source.Dispose()
    $iosSource.Dispose()
}
