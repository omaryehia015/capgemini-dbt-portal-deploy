# Builds the Windows installer from DbtPortalSetup.ps1:
#
#   DbtPortalSetup.exe     the app clients download and run (no SDK needed to
#                          build: the C# compiler ships with Windows)
#   Install-DbtPortal.cmd  the same window as a script, for places that block .exe
#
#   .\build.ps1                       # writes both into ..\download
#   .\build.ps1 -Out C:\somewhere
[CmdletBinding()]
param([string]$Out = (Join-Path $PSScriptRoot "..\download"))
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory $Out -Force | Out-Null
$Out = (Resolve-Path $Out).Path
$script = Join-Path $PSScriptRoot "DbtPortalSetup.ps1"
$work = Join-Path ([IO.Path]::GetTempPath()) ("dbt-portal-build-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory $work | Out-Null

# The icon: a blue tile with "dbt", as one 256 px PNG inside an .ico.
$size = 256
$bmp = New-Object Drawing.Bitmap($size, $size)
$g = [Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = "AntiAlias"
$g.TextRenderingHint = "AntiAliasGridFit"
$g.Clear([Drawing.Color]::Transparent)
$path = New-Object Drawing.Drawing2D.GraphicsPath
$r = 56; $d = $r * 2; $w = $size - 1
$path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($w - $d, 0, $d, $d, 270, 90)
$path.AddArc($w - $d, $w - $d, $d, $d, 0, 90); $path.AddArc(0, $w - $d, $d, $d, 90, 90); $path.CloseFigure()
$g.FillPath((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(0, 112, 173))), $path)
$font = New-Object Drawing.Font("Segoe UI", 84, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$fmt = New-Object Drawing.StringFormat
$fmt.Alignment = "Center"; $fmt.LineAlignment = "Center"
$g.DrawString("dbt", $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 0, $size, $size)), $fmt)
$g.Dispose()
$png = New-Object IO.MemoryStream
$bmp.Save($png, [Drawing.Imaging.ImageFormat]::Png)
$bytes = $png.ToArray()
$ico = Join-Path $work "portal.ico"
$fs = [IO.File]::Create($ico)
$bw = New-Object IO.BinaryWriter($fs)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)            # header: icon, one image
$bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0) # 256x256, no palette
$bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]$bytes.Length); $bw.Write([UInt32]22)
$bw.Write($bytes)
$bw.Close()

# The .exe: the compiler that comes with the .NET Framework on every Windows.
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
$exe = Join-Path $Out "DbtPortalSetup.exe"
& $csc /nologo /target:winexe /optimize+ "/win32icon:$ico" "/resource:$script,DbtPortalSetup.ps1" "/out:$exe" `
    /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot "Launcher.cs")
if ($LASTEXITCODE -ne 0) { throw "csc failed" }

# The .cmd: a batch header that hands the rest of the file to PowerShell.
$header = @'
<# : dbt Portal Setup. Double-click to run.
@echo off
setlocal
set "PORTAL_INSTALLER=%~f0"
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "& ([scriptblock]::Create([IO.File]::ReadAllText($env:PORTAL_INSTALLER)))"
exit /b
#>
'@
$body = [IO.File]::ReadAllText($script)
$cmd = ($header.TrimEnd() + "`r`n" + $body) -replace "(?<!`r)`n", "`r`n"
[IO.File]::WriteAllText((Join-Path $Out "Install-DbtPortal.cmd"), $cmd, (New-Object Text.ASCIIEncoding))

Remove-Item $work -Recurse -Force
Get-Item $exe, (Join-Path $Out "Install-DbtPortal.cmd") | ForEach-Object { "{0}  {1:N0} bytes" -f $_.FullName, $_.Length }
