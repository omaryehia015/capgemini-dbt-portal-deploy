# Runs the dbt Portal (microservices stack) for one dbt project on Windows,
# from the pre-built images. Needs Docker Desktop, or Podman Desktop with a
# compose provider; no build, no Python/Node/dbt on this machine.
#
#   .\setup.ps1                                               # connect the dbt project (Git) in the portal
#   .\setup.ps1 -ProjectsRoot C:\work                         # share a folder; pick the project in the portal
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
# Private images: set $env:PORTAL_TOKEN (a read-only registry token, with
# $env:PORTAL_USER_NAME to override the user name the token belongs to) and the
# script signs in for you.
# If Windows blocks the script: powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Project ...
[CmdletBinding()]
param(
    [string]$Project,
    [string]$ProjectsRoot,
    [int]$Port = 0,
    [string]$Release,
    [int]$Workers = 1,
    [string]$Answers,
    [switch]$NonInteractive,
    [switch]$SkipPull,
    [switch]$NoBrowser,
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
    foreach ($raw in Get-Content $Answers -Encoding UTF8) {
        $line = ($raw -replace '#.*$', '').Trim()
        if ($line -notmatch '^([^=]+)=(.*)$') { continue }
        $key = $Matches[1].Trim(); $value = $Matches[2].Trim()
        switch ($key) {
            "PROJECT" { if (-not $Project) { $Project = $value } }
            "PROJECTS_ROOT" { if (-not $ProjectsRoot) { $ProjectsRoot = $value } }
            "PORT" { if ($Port -eq 0) { $Port = [int]$value } }
            "RELEASE" { if (-not $Release) { $Release = $value } }
            "WORKERS" { $Workers = [int]$value }
            default { $extraEnv[$key] = $value }
        }
    }
}

# -- 2. The dbt project --------------------------------------------------------
# No folder given: the portal gets the project from a Git repository you connect
# in its Setup Assistant (the portal keeps its own copy). A folder is mounted live.
if (-not $Project -and -not $ProjectsRoot -and -not $NonInteractive) {
    Say "Your dbt project"
    Write-Host "  1) A Git repository (you connect it in the portal; recommended)"
    Write-Host "  2) A folder on this machine (you pick the project in the portal)"
    if ((Read-Host "Choose 1 or 2 [1]") -eq "2") {
        $ProjectsRoot = Read-Host "Folder that holds your dbt project (or several; a parent folder is fine)"
    }
}
# The portal keeps its own workspace volume unless one fixed project folder is mounted.
$GitMode = -not $Project
if ($ProjectsRoot) {
    $ProjectsRoot = $ProjectsRoot.Trim('"')
    if (-not (Test-Path $ProjectsRoot -PathType Container)) { Fail "The folder '$ProjectsRoot' does not exist." }
    $ProjectsRoot = (Resolve-Path $ProjectsRoot).Path
    Ok "Sharing $ProjectsRoot with the portal: you pick the project in the Setup Assistant"
    if ($Project) { Warn "-Project is used as a fixed project; -ProjectsRoot only adds the shared folder." }
}
if ($GitMode) {
    if (-not $ProjectsRoot) { Ok "The project is connected in the portal (Setup Assistant)" }
} else {
    $Project = $Project.Trim('"')
    if (-not (Test-Path (Join-Path $Project "dbt_project.yml"))) { Fail "No dbt_project.yml in '$Project'." }
    $Project = (Resolve-Path $Project).Path
    if (-not (Test-Path (Join-Path $Project ".env"))) {
        Warn "$Project\.env is missing. The portal reads the warehouse credentials from it."
    }
}

# -- 3. .env: secrets once, project / port / versions every run ----------------
function New-Secret { $b = New-Object byte[] 30; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ([Convert]::ToBase64String($b) -replace '[/+=]', '') }
if (-not (Test-Path .env)) { Say "Writing .env with generated secrets"; Copy-Item .env.example .env }
foreach ($key in "JWT_SECRET", "CUBE_API_SECRET", "POSTGRES_PASSWORD", "REDIS_PASSWORD") {
    if (-not (Get-Env $key)) { Set-Env $key (New-Secret) }
}

# Podman's Windows client mangles absolute paths (/mnt/c/mnt/c/...): give it a folder
# relative to compose.yaml. Docker Desktop takes the Windows path.
function Get-MountPath($folder) {
    if ($E -eq "podman") {
        $from = New-Object Uri ($Root.TrimEnd('\') + '\')
        $rel = [Uri]::UnescapeDataString($from.MakeRelativeUri((New-Object Uri $folder)).ToString())
        if (-not $rel.StartsWith("file:")) { return $rel.TrimEnd('/') }
    }
    return ($folder -replace '\\', '/')
}
if ($GitMode) {
    # Empty: compose falls back to its own workspace volume, where the portal clones the repository.
    Set-Env DBT_PROJECT_PATH ""
} else {
    Set-Env DBT_PROJECT_PATH (Get-MountPath $Project)
}
# The host folder shared with the portal; empty falls back to an unused volume.
if ($ProjectsRoot) {
    Set-Env DBT_PROJECTS_ROOT (Get-MountPath $ProjectsRoot)
    Set-Env PORTAL_PROJECTS_HOST ($ProjectsRoot -replace '\\', '/')
} else {
    Set-Env DBT_PROJECTS_ROOT ""
    Set-Env PORTAL_PROJECTS_HOST ""
}
if ($Port -gt 0) { Set-Env PORTAL_PORT $Port }
$Port = if (Get-Env PORTAL_PORT) { [int](Get-Env PORTAL_PORT) } else { 8080 }
# Taken by another program (or reserved by Windows): move to the next free port rather than fail.
$chosen = Select-Port $Port
if ($chosen -ne $Port) {
    Warn "Port $Port is used by another program: the portal uses port $chosen instead."
    $Port = $chosen; Set-Env PORTAL_PORT $Port
}
foreach ($key in $extraEnv.Keys) { Set-Env $key $extraEnv[$key] }
if ($extraEnv.Count) { Say "Applied $($extraEnv.Count) setting(s) from $Answers" }
# Bind mounts on Windows show every file as root-owned: run as root so `dbt deps` can write.
if (-not $GitMode -or $ProjectsRoot) { Set-Env PORTAL_USER "0:0" }

if ($Release) {
    $text = Get-Content releases.yml -Raw -Encoding UTF8
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
if (-not $GitMode) {
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
}

# -- 4. Pull and start ---------------------------------------------------------
# GHCR accepts a token only with the GitHub name of its owner: ask GitHub whose it is.
function Get-RegistryUser($plain) {
    if ($env:PORTAL_USER_NAME) { return $env:PORTAL_USER_NAME }
    try {
        $me = Invoke-RestMethod -Headers @{ Authorization = "Bearer $plain" } -TimeoutSec 15 "https://api.github.com/user"
        if ($me.login) { return $me.login }
    } catch { }
    return "portal"
}
function Sign-In($user, $plain) {
    $registry = if (Get-Env IMAGE_REGISTRY) { Get-Env IMAGE_REGISTRY } else { "ghcr.io/omaryehia015" }
    $plain | & $E login ($registry -split '/')[0] -u $user --password-stdin *> $null
    if ($LASTEXITCODE -ne 0) { Fail "The registry did not accept that token." }
    Ok "Signed in to $(($registry -split '/')[0])"
    Test-ImageAccess $user $plain
}
# GHCR also signs in tokens that cannot read the packages, and the pull would
# fail minutes later: ask for one image's manifest first, as the pull will.
function Test-ImageAccess($user, $plain) {
    $registry = if (Get-Env IMAGE_REGISTRY) { Get-Env IMAGE_REGISTRY } else { "ghcr.io/omaryehia015" }
    $parts = $registry -split '/', 2
    if ($parts[0] -ne "ghcr.io") { return }
    $repo = $parts[1] + "/capgemini-dbt-portal-backend"
    $tag = if (Get-Env BACKEND_TAG) { Get-Env BACKEND_TAG } else { "latest" }
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${user}:$plain"))
    $accept = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
    try {
        $t = Invoke-RestMethod -TimeoutSec 20 -Headers @{ Authorization = "Basic $basic" } "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io"
        Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec 20 -Headers @{ Authorization = "Bearer $($t.token)"; Accept = $accept } "https://ghcr.io/v2/$repo/manifests/$tag" | Out-Null
    } catch {
        Fail "This token cannot download the portal images. Ask for a new one: a GitHub token (classic) with the read:packages scope, made by an account that can see the portal packages. ($repo`:$tag)"
    }
    Ok "The token can download the portal images"
}
# Podman with an external compose provider (docker-compose) pulls without the
# login podman keeps, so podman pulls the images itself and compose finds them.
function Pull-Images {
    if ($E -eq "podman") {
        # Private images first: a token problem shows before the big downloads.
        $images = & $E compose config --images 2>$null | Where-Object { $_ -and $_ -notmatch '^>>>>' } | Sort-Object -Unique -Descending
        if ($images) {
            foreach ($image in $images) {
                Write-Host "  $image"
                & $E pull $image | Out-Host
                if ($LASTEXITCODE -ne 0) { return $false }
            }
            return $true
        }
    }
    & $E compose pull | Out-Host
    return ($LASTEXITCODE -eq 0)
}
if (-not $SkipPull) {
    $ErrorActionPreference = "Continue"
    if ($env:PORTAL_TOKEN) {
        Say "Signing in to the image registry"
        Sign-In (Get-RegistryUser $env:PORTAL_TOKEN) $env:PORTAL_TOKEN
    }
    Say "Downloading the portal images (a few minutes the first time)"
    if (-not (Pull-Images)) {
        if ($NonInteractive) { Fail "Pulling the images failed. Set PORTAL_TOKEN, or sign in first: $E login ghcr.io" }
        Write-Host ""
        Write-Host "The images are private. Paste the access token you were sent."
        $token = Read-Host "Token" -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($token))
        Sign-In (Get-RegistryUser $plain) $plain
        if (-not (Pull-Images)) { Fail "Pulling the images failed with that token." }
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
$url = "http://localhost:$Port/setup"
$next = if ($ProjectsRoot) { "Step 2 of the Setup Assistant: pick your project from the folder you shared (or use Git)." } elseif ($GitMode) { "Step 2 of the Setup Assistant connects your dbt project (Git)." } else { "Setup Assistant: workspace, warehouse, dbt project, team." }
Write-Host ""
Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |  The portal is running                                   |" -ForegroundColor Cyan
Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "    Open:    $url"
Write-Host "    Sign in: admin (password above; change it under My account)"
Write-Host "    Then:    $next"
@"

Day to day (from $Root):
  .\manage.ps1 status            # what is running, and whether it is healthy
  .\manage.ps1 logs execution    # follow a service's log
  .\manage.ps1 doctor            # check this machine and the stack
  .\manage.ps1 help              # everything else
"@
if (-not $NoBrowser -and -not $NonInteractive) { Start-Process $url }
