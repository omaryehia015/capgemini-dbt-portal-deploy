# Runs the dbt Portal for one dbt project on Windows, from the pre-built images.
# Needs only Docker Desktop or Podman Desktop: no compose, no build, no Python/Node/dbt.
#
#   .\setup.ps1 -Project C:\work\my-dbt-project
#   .\setup.ps1 -Project C:\work\my-dbt-project -Port 8081 -Tag 1.2.0
#   .\setup.ps1 -Project C:\work\my-dbt-project -SkipPull   # images already here (docker load)
#
# Run it again to upgrade or change the port: accounts and history are kept.
# Optional portal settings (LDAP, SMTP, AI keys...) go in a .env next to this
# script, see .env.example. Warehouse credentials stay in the project's own .env.
# If Windows blocks the script: powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Project ...
[CmdletBinding()]
param(
    [string]$Project,
    [int]$Port = 8080,
    [string]$Tag = "latest",
    [string]$Registry = "ghcr.io/omaryehia015/capgemini-dbt-portal",
    [switch]$SkipPull
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Say($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "ERROR: $text" -ForegroundColor Red; exit 1 }
# Native commands: run quietly, report success. (Windows PowerShell turns their
# stderr into errors, so it is silenced here and checked through the exit code.)
function Try-Run { $ErrorActionPreference = "Continue"; & $E @args *> $null; return ($LASTEXITCODE -eq 0) }

# -- 1. Docker or Podman -------------------------------------------------------
$E = $null
foreach ($candidate in "docker", "podman") {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) {
        $E = $candidate
        if (Try-Run info) { break }
        $E = $null
    }
}
if (-not $E) { Fail "Start Docker Desktop (or Podman Desktop) first." }
Say "Using $E"

# -- 2. The dbt project --------------------------------------------------------
if (-not $Project) { $Project = Read-Host "Path to your dbt project (the folder with dbt_project.yml)" }
$Project = $Project.Trim('"')
if (-not (Test-Path (Join-Path $Project "dbt_project.yml"))) { Fail "No dbt_project.yml in '$Project'." }
$Project = (Resolve-Path $Project).Path
if (-not (Test-Path (Join-Path $Project ".env"))) {
    Write-Host "WARNING: $Project\.env is missing. The portal reads the warehouse credentials from it." -ForegroundColor Yellow
}

# Where profiles.yml is: in the project (seen as /workspace), or ~\.dbt.
$extra = @()
$userDbt = Join-Path $env:USERPROFILE ".dbt"
if (Test-Path (Join-Path $Project "profiles.yml")) { }
elseif (Test-Path (Join-Path $Project "profiles\profiles.yml")) { $extra += "-e", "DBT_PROFILES_DIR=/workspace/profiles" }
elseif (Test-Path (Join-Path $userDbt "profiles.yml")) { $extra += "-v", "${userDbt}:/profiles:ro", "-e", "DBT_PROFILES_DIR=/profiles" }
else { Write-Host "WARNING: no profiles.yml found in the project or $userDbt." -ForegroundColor Yellow }
if (Test-Path .env) { $extra += "--env-file", ".env" }

# One set of names per project, so several projects can run side by side.
$slug = ((Split-Path $Project -Leaf).ToLower() -replace '[^a-z0-9]', '-')
$Name = "dbt-portal-$slug"
Say "Project $Project -> containers $Name-*"

# -- 3. Pull the images (sign in if they are private) --------------------------
$Backend = "${Registry}-backend:$Tag"
$Frontend = "${Registry}-frontend:$Tag"
if ($SkipPull) {
    if (-not ((Try-Run image inspect $Backend) -and (Try-Run image inspect $Frontend))) { Fail "$Backend / $Frontend are not on this machine." }
    Say "Using the images already on this machine"
    $pulled = $true
}
else {
    Say "Pulling $Backend and $Frontend"
    $pulled = (Try-Run pull $Backend) -and (Try-Run pull $Frontend)
}
if (-not $pulled) {
    Write-Host "The images need a sign-in. Use the registry username and read-only token you were given."
    $user = Read-Host "Registry username"
    $secure = Read-Host "Token (hidden)" -AsSecureString
    $token = [System.Net.NetworkCredential]::new("", $secure).Password
    $token | & $E login ($Registry.Split("/")[0]) -u $user --password-stdin
    if ($LASTEXITCODE -ne 0) { Fail "Sign-in refused." }
    & $E pull $Backend; if ($LASTEXITCODE -ne 0) { Fail "Could not pull $Backend." }
    & $E pull $Frontend; if ($LASTEXITCODE -ne 0) { Fail "Could not pull $Frontend." }
}

# -- 4. Start (replaces old containers; the data volume is kept) ---------------
Say "Starting"
Try-Run rm -f "$Name-frontend" "$Name-backend" | Out-Null
Try-Run network create $Name | Out-Null
Try-Run volume create "$Name-data" | Out-Null
# Root inside the container: Windows bind mounts need it for `dbt deps`.
$ok = Try-Run run -d --name "$Name-backend" --network $Name --network-alias backend --restart unless-stopped `
    --user 0:0 -e DBT_PROJECT_DIR=/workspace -e ENVIRONMENT=production `
    -v "${Project}:/workspace" -v "${Name}-data:/data" @extra $Backend
if (-not $ok) { Fail "Could not start the backend. Try: $E run --rm $Backend" }
$ok = Try-Run run -d --name "$Name-frontend" --network $Name --restart unless-stopped `
    -p "${Port}:8080" -e BACKEND_UPSTREAM=backend:8000 $Frontend
if (-not $ok) { Fail "Could not start the frontend (port $Port taken?). Try: .\setup.ps1 -Project '$Project' -Port 8081" }

Write-Host -NoNewline "Waiting for the portal"
$ready = $false
foreach ($attempt in 1..60) {
    try {
        Invoke-WebRequest "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 5 | Out-Null
        $ready = $true; break
    } catch { Write-Host -NoNewline "."; Start-Sleep -Seconds 5 }
}
Write-Host ""
if (-not $ready) { Fail "Not up after 5 minutes. See: $E logs $Name-backend" }

# -- 5. First sign-in ----------------------------------------------------------
Say "Portal is up: http://localhost:$Port"
$ErrorActionPreference = "Continue"
[string[]]$logs = & $E logs "$Name-backend" 2>&1 | ForEach-Object { "$_" }
$at = [array]::FindIndex($logs, [Predicate[string]] { param($l) $l -match "GENERATED INITIAL CREDENTIALS" })
if ($at -ge 0) { $logs[$at..([Math]::Min($at + 5, $logs.Count - 1))] | ForEach-Object { Write-Host $_ -ForegroundColor Green } }
else { Write-Host "No new passwords printed: the accounts already exist from an earlier run." }

Write-Host @"

Next:
  1. Open http://localhost:$Port and sign in as 'admin' (password printed on the first run).
  2. Change it under My account.
  3. Open Onboarding and run the steps (install packages, provision, build, reports).

Manage:
  $E logs -f $Name-backend   # what the backend is doing
  $E stop $Name-frontend $Name-backend   # stop
  $E start $Name-backend $Name-frontend   # start again
  $E rm -f $Name-frontend $Name-backend; $E volume rm $Name-data   # uninstall (deletes accounts)
"@
Start-Process "http://localhost:$Port"
