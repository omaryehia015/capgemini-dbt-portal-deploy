# Runs the dbt Portal (microservices stack) for one dbt project on Windows,
# from the pre-built images. Needs Docker Desktop, or Podman Desktop with a
# compose provider; no build, no Python/Node/dbt on this machine.
#
#   .\setup.ps1 -Project C:\work\my-dbt-project
#   .\setup.ps1 -Project C:\work\my-dbt-project -Port 8081 -Release 2026.10.0
#   .\setup.ps1 -Project C:\work\my-dbt-project -SkipPull     # images already here (docker load)
#   .\setup.ps1 -Project C:\work\my-dbt-project -Workers 3    # run more dbt jobs at once
#
# The first run writes .env next to compose.yaml with generated secrets; later
# runs keep it (accounts, history and sessions survive upgrades). Optional
# portal settings (LDAP, SMTP, AI keys...) go in that .env too.
# Warehouse credentials stay in the project's own .env.
# If Windows blocks the script: powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Project ...
[CmdletBinding()]
param(
    [string]$Project,
    [int]$Port = 0,
    [string]$Release,
    [int]$Workers = 1,
    [switch]$SkipPull
)
$ErrorActionPreference = "Stop"
# Works from the repo (deploy\client\) and from the unpacked client kit (flat).
$Root = if (Test-Path (Join-Path $PSScriptRoot "compose.yaml")) { $PSScriptRoot } else { (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path }
Set-Location $Root

function Say($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "ERROR: $text" -ForegroundColor Red; exit 1 }
# Native commands: run quietly, report success. (Windows PowerShell turns their
# stderr into errors, so it is silenced here and checked through the exit code.)
function Try-Run($exe) { $ErrorActionPreference = "Continue"; & $exe @args *> $null; return ($LASTEXITCODE -eq 0) }
function Compose { $ErrorActionPreference = "Continue"; & $E compose @args; if ($LASTEXITCODE -ne 0) { Fail "$E compose $($args -join ' ') failed." } }

# -- 1. Docker or Podman, with compose -----------------------------------------
$E = $null
foreach ($candidate in "docker", "podman") {
    if ((Get-Command $candidate -ErrorAction SilentlyContinue) -and (Try-Run $candidate info) -and (Try-Run $candidate compose version)) {
        $E = $candidate; break
    }
}
if (-not $E) { Fail "Start Docker Desktop (or Podman Desktop with a compose provider: pip install podman-compose) first." }
Say "Using $E compose"

# -- 2. The dbt project --------------------------------------------------------
if (-not $Project) { $Project = Read-Host "Path to your dbt project (the folder with dbt_project.yml)" }
$Project = $Project.Trim('"')
if (-not (Test-Path (Join-Path $Project "dbt_project.yml"))) { Fail "No dbt_project.yml in '$Project'." }
$Project = (Resolve-Path $Project).Path
if (-not (Test-Path (Join-Path $Project ".env"))) {
    Write-Host "WARNING: $Project\.env is missing. The portal reads the warehouse credentials from it." -ForegroundColor Yellow
}

# -- 3. .env: secrets once, project / port / versions every run ----------------
function New-Secret { $b = New-Object byte[] 30; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ([Convert]::ToBase64String($b) -replace '[/+=]', '') }
function Get-Env($key) {
    if (-not (Test-Path .env)) { return "" }
    $line = Get-Content .env | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
    if ($line) { return $line.Substring($key.Length + 1) } else { return "" }
}
function Set-Env($key, $value) {
    $lines = @(); if (Test-Path .env) { $lines = @(Get-Content .env) }
    $found = $false
    $lines = $lines | ForEach-Object { if ($_ -match "^$key=") { $found = $true; "$key=$value" } else { $_ } }
    if (-not $found) { $lines += "$key=$value" }
    # UTF-8 without BOM: compose reads the first key with a BOM as a different name.
    [IO.File]::WriteAllLines((Join-Path $Root ".env"), [string[]]$lines, (New-Object Text.UTF8Encoding $false))
}

if (-not (Test-Path .env)) { Say "Writing .env with generated secrets"; Copy-Item .env.example .env }
foreach ($key in "JWT_SECRET", "CUBE_API_SECRET", "POSTGRES_PASSWORD", "REDIS_PASSWORD") {
    if (-not (Get-Env $key)) { Set-Env $key (New-Secret) }
}

# Podman's Windows client mangles absolute paths (/mnt/c/mnt/c/...): give it
# the project relative to compose.yaml. Docker Desktop takes the Windows path.
$projectPath = $Project
if ($E -eq "podman") {
    $from = New-Object Uri ($Root.TrimEnd('\') + '\')
    $rel = [Uri]::UnescapeDataString($from.MakeRelativeUri((New-Object Uri $Project)).ToString())
    if (-not $rel.StartsWith("file:")) { $projectPath = $rel.TrimEnd('/') }
}
Set-Env DBT_PROJECT_PATH ($projectPath -replace '\\', '/')
if ($Port -gt 0) { Set-Env PORTAL_PORT $Port }
$Port = if (Get-Env PORTAL_PORT) { [int](Get-Env PORTAL_PORT) } else { 8080 }
# Bind mounts on Windows show every file as root-owned: run as root so `dbt deps` can write.
Set-Env PORTAL_USER "0:0"

if ($Release) {
    $text = Get-Content releases.yml -Raw
    if ($Release -eq "latest") { $Release = ([regex]::Match($text, '(?m)^latest:\s*"?([^"\r\n]+)"?')).Groups[1].Value }
    $block = [regex]::Match($text, '(?ms)^  "' + [regex]::Escape($Release) + '":\s*\r?\n(.*?)(?=^  "|\z)')
    if (-not $block.Success) { Fail "Release '$Release' is not in releases.yml." }
    foreach ($part in "backend", "frontend", "cube") {
        $tag = ([regex]::Match($block.Groups[1].Value, '(?m)^\s*' + $part + ':\s*"?([^"\r\n]+)"?')).Groups[1].Value
        Set-Env "$($part.ToUpper())_TAG" $tag
    }
    Say "Release ${Release}: backend $(Get-Env BACKEND_TAG), frontend $(Get-Env FRONTEND_TAG), cube $(Get-Env CUBE_TAG)"
}

# Where profiles.yml is: in the project (seen as /workspace), or ~\.dbt.
Remove-Item compose.override.yaml -ErrorAction SilentlyContinue
$userDbt = Join-Path $env:USERPROFILE ".dbt"
if (Test-Path (Join-Path $Project "profiles.yml")) { }
elseif (Test-Path (Join-Path $Project "profiles\profiles.yml")) { Set-Env DBT_PROFILES_DIR "/workspace/profiles" }
elseif (Test-Path (Join-Path $userDbt "profiles.yml")) {
    Set-Env DBT_PROFILES_DIR "/profiles"
    $mount = ($userDbt -replace '\\', '/') + ":/profiles:ro"
    $override = @("# Written by setup.ps1: profiles.yml comes from ~\.dbt on this machine.", "services:")
    foreach ($svc in "execution", "worker", "insights", "semantic") { $override += "  ${svc}:", "    volumes: [""$mount""]" }
    [IO.File]::WriteAllLines((Join-Path $Root "compose.override.yaml"), [string[]]$override, (New-Object Text.UTF8Encoding $false))
}
else { Write-Host "WARNING: no profiles.yml found in the project or $userDbt." -ForegroundColor Yellow }

# -- 4. Pull and start ---------------------------------------------------------
if (-not $SkipPull) {
    Say "Pulling images"
    $ErrorActionPreference = "Continue"
    & $E compose pull --quiet *> $null
    if ($LASTEXITCODE -ne 0) {
        $registry = if (Get-Env IMAGE_REGISTRY) { Get-Env IMAGE_REGISTRY } else { "ghcr.io/omaryehia015" }
        Write-Host "The images need a sign-in. Use the registry username and read-only token you were given."
        $user = Read-Host "Registry username"
        $token = Read-Host "Token" -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($token))
        $plain | & $E login ($registry -split '/')[0] -u $user --password-stdin
        Compose pull --quiet
    }
    $ErrorActionPreference = "Stop"
}
Say "Starting (this takes a minute on first start: databases, migrations)"
Compose up -d --remove-orphans --scale "worker=$Workers"

Write-Host -NoNewline "Waiting for the portal"
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://localhost:$Port/api/health" | Out-Null; $ready = $true; break }
    catch { Write-Host -NoNewline "."; Start-Sleep -Seconds 5 }
}
Write-Host ""
if (-not $ready) { Fail "Not up after 5 minutes. See: $E compose ps; $E compose logs identity execution" }

# -- 5. First sign-in ----------------------------------------------------------
Say "Portal is up: http://localhost:$Port"
$ErrorActionPreference = "Continue"
$creds = (& $E compose logs identity 2>&1 | Out-String) -split "`n" | Select-String -Pattern "GENERATED INITIAL CREDENTIALS" -Context 0, 5
if ($creds) { $creds | ForEach-Object { $_.Line; $_.Context.PostContext } } else { "No new passwords printed: the accounts already exist from an earlier run." }
@"

Next:
  1. Open http://localhost:$Port and sign in as 'admin' (password printed on the first run).
  2. Change it under My account.
  3. Open Onboarding and run the steps (install packages, provision, build, reports).

Manage (from $Root):
  $E compose ps                          # what is running
  $E compose logs -f execution worker    # dbt runs
  $E compose up -d --scale worker=3      # more dbt jobs at once
  $E compose stop / $E compose start     # stop, start again
  $E compose down -v                     # uninstall (deletes accounts and history)
"@
