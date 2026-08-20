# screenshot.ps1 - capture the primary screen to a PNG for agent inspection.
# Usage: .\screenshot.ps1 [-OutFile path] [-MaxWidth 1600]
# ASCII only (PS 5.1 reads BOM-less UTF-8 as CP1252).
param(
    [string]$OutFile = "$env:TEMP\wh3_screen.png",
    [int]$MaxWidth = 1600
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$g.Dispose()

if ($MaxWidth -gt 0 -and $bmp.Width -gt $MaxWidth) {
    $scale = $MaxWidth / $bmp.Width
    $newH = [int]($bmp.Height * $scale)
    $small = New-Object System.Drawing.Bitmap $MaxWidth, $newH
    $g2 = [System.Drawing.Graphics]::FromImage($small)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($bmp, 0, 0, $MaxWidth, $newH)
    $g2.Dispose()
    $bmp.Dispose()
    $bmp = $small
}

$bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output $OutFile
