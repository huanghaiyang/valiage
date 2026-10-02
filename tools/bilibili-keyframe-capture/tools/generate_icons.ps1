# generate_icons.ps1 -- generate extension icons with System.Drawing (no third-party libs)
# Usage: powershell -ExecutionPolicy Bypass -File tools/bilibili-keyframe-capture/tools/generate_icons.ps1
Add-Type -AssemblyName System.Drawing

$outDir = Join-Path $PSScriptRoot '..\icons'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outDir = (Resolve-Path $outDir).Path

function New-IconPng {
    param([int]$Size, [string]$FilePath)

    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear([System.Drawing.Color]::Transparent)

    # rounded dark background
    $rect = [System.Drawing.Rectangle]::new(0, 0, $Size, $Size)
    $bg = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        $rect,
        [System.Drawing.Color]::FromArgb(255, 34, 38, 45),
        [System.Drawing.Color]::FromArgb(255, 20, 23, 28),
        45.0)
    $radius = [Math]::Max(2, [int]($Size * 0.22))
    $shape = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = $radius * 2
    $shape.AddArc(0, 0, $d, $d, 180, 90)
    $shape.AddArc($Size - $d, 0, $d, $d, 270, 90)
    $shape.AddArc($Size - $d, $Size - $d, $d, $d, 0, 90)
    $shape.AddArc(0, $Size - $d, $d, $d, 90, 90)
    $shape.CloseFigure()
    $g.FillPath($bg, $shape)
    $borderPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 58, 64, 73), [Math]::Max(1, $Size / 32))
    $g.DrawPath($borderPen, $shape)

    # pink play triangle
    $pink = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 251, 114, 153))
    $tri = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([single]($Size * 0.34), [single]($Size * 0.28)),
        [System.Drawing.PointF]::new([single]($Size * 0.34), [single]($Size * 0.72)),
        [System.Drawing.PointF]::new([single]($Size * 0.74), [single]($Size * 0.50))
    )
    $g.FillPolygon($pink, $tri)
    $triPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 255, 180, 205), [Math]::Max(1, $Size / 48))
    $g.DrawPolygon($triPen, $tri)

    # frame marker dot (keyframe hint)
    $dot = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
    $dotSize = [Math]::Max(1, [int]($Size * 0.09))
    $g.FillEllipse($dot, [single]($Size * 0.22), [single]($Size * 0.455), $dotSize, $dotSize)

    $g.Dispose()
    $bmp.Save($FilePath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("wrote {0} ({1} bytes)" -f $FilePath, (Get-Item $FilePath).Length)
}

foreach ($size in 16, 32, 48, 128) {
    New-IconPng -Size $size -FilePath (Join-Path $outDir "icon$size.png")
}
