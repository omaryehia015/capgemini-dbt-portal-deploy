# Run the whole portal on this machine from the sibling repos' source.
#
#   .\run-local.ps1                       # uses ..\capgemini_dbt_core as the dbt project
#   .\run-local.ps1 -Project C:\work\my-dbt-project -Port 8090
#   .\run-local.ps1 -Down                 # stop it (data is kept; add -Wipe to delete it)
#
# Needs Docker or Podman with compose, and the backend, frontend and cube repos
# checked out next to this one. First run builds the images (several minutes).
# Sign in as admin / admin123! (development mode: demo passwords).
[CmdletBinding()]
param(
    [string]$Project = (Join-Path $PSScriptRoot "..\capgemini_dbt_core"),
    [int]$Port = 8090,
    [switch]$Down,
    [switch]$Wipe
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
# Podman needs a compose provider (docker-compose or podman-compose) on PATH.
$userBin = Join-Path $env:USERPROFILE "bin"
if ((Test-Path (Join-Path $userBin "docker-compose.exe")) -and ($env:PATH -notlike "*$userBin*")) { $env:PATH += ";$userBin" }
$engine = if (Get-Command podman -ErrorAction SilentlyContinue) { "podman" } else { "docker" }
$compose = @($engine, "compose", "-p", "portal", "-f", "compose.yaml", "-f", "compose.build.yaml")

if ($Down) {
    $ErrorActionPreference = "Continue"
    & $compose[0] $compose[1..($compose.Length - 1)] down $(if ($Wipe) { "-v" }) 2>&1 | ForEach-Object { "$_" }
    exit $LASTEXITCODE
}

$project = (Resolve-Path $Project).Path
if (-not (Test-Path (Join-Path $project "dbt_project.yml"))) { throw "No dbt_project.yml in $project" }
# Podman on Windows mangles absolute paths, so a project next to this repo is given
# as ../<folder>; anything else as an absolute path with forward slashes.
$here = (Resolve-Path $PSScriptRoot).Path
if ((Split-Path $project -Parent) -eq (Split-Path $here -Parent)) { $rel = "../" + (Split-Path $project -Leaf) }
else { $rel = $project -replace '\', '/' }

function Secret { -join ((48..57) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }) }
$old = @{}
if (Test-Path .env) { Get-Content .env | ForEach-Object { if ($_ -match '^([A-Z_]+)=(.*)$') { $old[$Matches[1]] = $Matches[2] } } }
$keep = { param($k) if ($old[$k]) { $old[$k] } else { Secret } }
@(
    "DBT_PROJECT_PATH=$rel", "PORTAL_PORT=$Port", "PORTAL_USER=0:0",
    "ENVIRONMENT=development", "LOG_FORMAT=text", "PREFLIGHT_ON_START=false",
    "JWT_SECRET=$(& $keep 'JWT_SECRET')", "CUBE_API_SECRET=$(& $keep 'CUBE_API_SECRET')",
    "POSTGRES_PASSWORD=$(& $keep 'POSTGRES_PASSWORD')", "REDIS_PASSWORD=$(& $keep 'REDIS_PASSWORD')"
) | Set-Content .env -Encoding ascii

# podman prints a notice on stderr; that is not a failure, so judge by the exit code.
$ErrorActionPreference = "Continue"
# One image at a time: building them all in parallel can exhaust a small Podman VM.
foreach ($svc in "identity", "execution", "insights", "semantic", "cube", "frontend") {
    & $compose[0] $compose[1..($compose.Length - 1)] build $svc 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "build of $svc failed" }
}
& $compose[0] $compose[1..($compose.Length - 1)] up -d 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "compose failed" }
Write-Host "`nPortal: http://localhost:$Port   (admin / admin123!)" -ForegroundColor Green
Write-Host "Stop:   .\run-local.ps1 -Down"
