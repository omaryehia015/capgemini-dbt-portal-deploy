# Runs the dbt Portal (microservices stack) for one dbt project on Windows,
# from the pre-built images. Needs Docker Desktop, or Podman Desktop with a
# compose provider; no build, no Python/Node/dbt on this machine.
#
#   .\setup.ps1 -Project C:\work\my-dbt-project
#   .\setup.ps1 -Project C:\work\my-dbt-project -Port 8081 -Release 2026.10.0
#   .\setup.ps1 -Project C:\work\my-dbt-project -SkipPull     # images already here (docker load)
#   .\setup.ps1 -Project C:\work\my-dbt-project -Workers 3    # run more dbt jobs at once
#   .\setup.ps1 -Answers portal.answers                       # zero-touch: no questions asked
#   .\setup.ps1 -Check                                         # only check this machine
#
# The first run writes .env next to compose.yaml with generated secrets; later
# runs keep it (accounts, history and sessions survive upgrades). Optional
# portal settings (LDAP, SMTP, AI keys, AIRFLOW_URL...) go in that .env too.
# Warehouse credentials stay in the project's own .env.
#
# An answers file is KEY=VALUE lines: PROJECT, PORT, RELEASE and WORKERS set
# the options above; any other key (AIRFLOW_URL, AIRBYTE_MODE=off, ...) is
# written to .env. See portal.answers.example.
# If Windows blocks the script: powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Project ...
[CmdletBinding()]
param(
    [string]$Project,
    [int]$Port = 0,
    [string]$Release,
    [int]$Workers = 1,
    [string]$Answers,
    [switch]$NonInteractive,
    [switch]$SkipPull,
    [switch]$Check
)
$ErrorActionPreference = "Stop"
# Works from the repo (deploy\client\) and from the unpacked client kit (flat).
$Root = if (Test-Path (Join-Path $PSScriptRoot "compose.yaml")) { $PSScriptRoot } else { (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path }
. (Join-Path $PSScriptRoot "lib.ps1")
Set-Location $Root

# -- 0. This machine -----------------------------------------------------------
if (-not (Test-Host $Root)) { Fail "Fix the items marked [x] above, then run this again." }
if ($Check) { exit 0 }
$E = $script:E
Say "Using $E compose"

# -- 1. Answers file -----------------------------------------------------------
$extraEnv = [ordered]@{}
if ($Answers) {
    $NonInteractive = $true
    if (-not (Test-Path $Answers)) { Fail "Answers file '$Answers' not found." }
    foreach ($raw in Get-Content $Answers) {
        $line = ($raw -replace '#.*$', '').Trim()
        if ($line -notmatch '^([^=]+)=(.*)$') { continue }
        $key = $Matches[1].Trim(); $value = $Matches[2].Trim()
        switch ($key) {
            "PROJECT" { if (-not $Project) { $Project = $value } }
            "PORT" { if ($Port -eq 0) { $Port = [int]$value } }
            "RELEASE" { if (-not $Release) { $Release = $value } }
            "WORKERS" { $Workers = [int]$value }
            default { $extraEnv[$key] = $value }
        }
    }
}

# -- 2. The dbt project --------------------------------------------------------
if (-not $Project) {
    if ($NonInteractive) { Fail "No dbt project given (PROJECT= in the answers file, or -Project)." }
    $Project = Read-Host "Path to your dbt project (the folder with dbt_project.yml)"
}
$Project = $Project.Trim('"')
if (-not (Test-Path (Join-Path $Project "dbt_project.yml"))) { Fail "No dbt_project.yml in '$Project'." }
$Project = (Resolve-Path $Project).Path
if (-not (Test-Path (Join-Path $Project ".env"))) {
    Warn "$Project\.env is missing. The portal reads the warehouse credentials from it."
}

# -- 3. .env: secrets once, project / port / versions every run ----------------
function New-Secret { $b = New-Object byte[] 30; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ([Convert]::ToBase64String($b) -replace '[/+=]', '') }
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
foreach ($key in $extraEnv.Keys) { Set-Env $key $extraEnv[$key] }
if ($extraEnv.Count) { Say "Applied $($extraEnv.Count) setting(s) from $Answers" }
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
else { Warn "No profiles.yml found in the project or $userDbt." }

# -- 4. Pull and start ---------------------------------------------------------
if (-not $SkipPull) {
    Say "Pulling images"
    $ErrorActionPreference = "Continue"
    & $E compose pull --quiet *> $null
    if ($LASTEXITCODE -ne 0) {
        if ($NonInteractive) { Fail "Pulling the images failed. Sign in first: $E login ghcr.io" }
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

if (-not (Wait-Healthy $Port)) { Fail "Not up after 5 minutes. See: .\manage.ps1 status; .\manage.ps1 logs identity" }

# -- 5. First sign-in ----------------------------------------------------------
Say "Portal is up: http://localhost:$Port"
$ErrorActionPreference = "Continue"
$creds = (& $E compose logs identity 2>&1 | Out-String) -split "\r?\n" | Where-Object { $_.Trim() } | Select-String -Pattern "GENERATED INITIAL CREDENTIALS" -Context 0, 5
if ($creds) { $creds | ForEach-Object { $_.Line; $_.Context.PostContext } } else { "No new passwords printed: the accounts already exist from an earlier run." }
@"

Next:
  1. Open http://localhost:$Port/setup and sign in as 'admin' (password printed on the first run).
  2. The Setup Assistant walks through the workspace, warehouse, dbt project, modules
     (Airbyte, Airflow, ...) and team.
  3. Change the admin password under My account.

Day to day (from $Root):
  .\manage.ps1 status            # what is running, and whether it is healthy
  .\manage.ps1 logs execution    # follow a service's log
  .\manage.ps1 doctor            # check this machine and the stack
  .\manage.ps1 help              # everything else
"@
