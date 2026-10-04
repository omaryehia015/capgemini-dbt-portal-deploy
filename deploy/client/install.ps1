# One-line install on Windows: downloads the client kit of a portal release and
# runs its setup.ps1.
#
#   irm https://raw.githubusercontent.com/omaryehia015/capgemini-dbt-portal-deploy/main/deploy/client/install.ps1 | iex
#
# Environment (set before running):
#   $env:PORTAL_TOKEN     the access token you were sent (downloads the kit, signs in to the images)
#   $env:PORTAL_PROJECT   a dbt project folder (not set: you connect a Git repository in the portal)
#   $env:PORTAL_RELEASE   release to install (default: latest)
#   $env:PORTAL_DIR       where to unpack the kit (default: ~\dbt-portal)
#   $env:GITHUB_TOKEN     same as PORTAL_TOKEN (older name)
$ErrorActionPreference = "Stop"
$repo = "omaryehia015/capgemini-dbt-portal-deploy"
$release = if ($env:PORTAL_RELEASE) { $env:PORTAL_RELEASE } else { "latest" }
$dir = if ($env:PORTAL_DIR) { $env:PORTAL_DIR } else { Join-Path $HOME "dbt-portal" }
$headers = @{}
if (-not $env:PORTAL_TOKEN -and $env:GITHUB_TOKEN) { $env:PORTAL_TOKEN = $env:GITHUB_TOKEN }
if ($env:PORTAL_TOKEN) { $headers["Authorization"] = "Bearer $env:PORTAL_TOKEN" }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($release -eq "latest") {
    $text = (Invoke-WebRequest -UseBasicParsing -Headers $headers "https://raw.githubusercontent.com/$repo/main/releases.yml").Content
    $release = ([regex]::Match($text, '(?m)^latest:\s*"?([^"\r\n]+)"?')).Groups[1].Value
    if (-not $release) { throw "Could not work out the latest release." }
}

$kit = "dbt-portal-client-kit-$release"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
$zip = Join-Path $tmp "kit.zip"
Write-Host "`n==> Downloading $kit" -ForegroundColor Cyan
if ($env:PORTAL_TOKEN) {
    # A private repository's assets come through the API.
    $rel = Invoke-RestMethod -Headers $headers "https://api.github.com/repos/$repo/releases/tags/portal-$release"
    $asset = $rel.assets | Where-Object { $_.name -eq "$kit.zip" } | Select-Object -First 1
    if (-not $asset) { throw "Release portal-$release has no client kit." }
    Invoke-WebRequest -UseBasicParsing -Headers ($headers + @{ Accept = "application/octet-stream" }) -OutFile $zip $asset.url
} else {
    Invoke-WebRequest -UseBasicParsing -OutFile $zip "https://github.com/$repo/releases/download/portal-$release/$kit.zip"
}
Expand-Archive -Path $zip -DestinationPath $tmp -Force

New-Item -ItemType Directory -Force $dir | Out-Null
# An existing install keeps its .env (secrets, settings) and override file.
Copy-Item -Path (Join-Path $tmp "$kit\*") -Destination $dir -Recurse -Force
Copy-Item -Path (Join-Path $tmp "$kit\.env.example") -Destination $dir -Force
Remove-Item -Recurse -Force $tmp
Write-Host "`n==> Kit unpacked in $dir" -ForegroundColor Cyan

$setupArgs = @()
if ($env:PORTAL_PROJECT) { $setupArgs += @("-Project", $env:PORTAL_PROJECT) }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir "setup.ps1") @setupArgs
