# Day-to-day operations for a portal installed with setup.ps1.
#
#   .\manage.ps1 status                 what is running, health, modules
#   .\manage.ps1 start|stop|restart [service...]
#   .\manage.ps1 logs [service]         follow logs (all services without one)
#   .\manage.ps1 doctor                 check this machine and the stack
#   .\manage.ps1 upgrade [release]      move to a release from releases.yml (default: latest)
#   .\manage.ps1 backup                 dump the portal databases to backups\
#   .\manage.ps1 reset-password [user]  a new password for an account (default: admin), shown once
#   .\manage.ps1 services               the service names, and what each does
#   .\manage.ps1 help
param(
    [Parameter(Position = 0)][string]$Command = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)
$ErrorActionPreference = "Stop"
$Root = if (Test-Path (Join-Path $PSScriptRoot "compose.yaml")) { $PSScriptRoot } else { (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path }
. (Join-Path $PSScriptRoot "lib.ps1")
Set-Location $Root

if (-not (Test-Path .env)) { Fail "No .env in ${Root}: install first with .\setup.ps1 -Project C:\path\to\dbt-project" }
$Port = if (Get-Env PORTAL_PORT) { [int](Get-Env PORTAL_PORT) } else { 8080 }

function Need-Runtime { if (-not (Find-Runtime)) { Fail "Docker or Podman with compose is not running. $(Install-Hint)" } }
function Test-Portal {
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://localhost:$Port/api/health" | Out-Null; return $true } catch { return $false }
}
function Show-Modules {
    foreach ($m in "AIRBYTE", "AIRFLOW") {
        $mode = Get-Env "${m}_MODE"; $url = Get-Env "${m}_URL"
        if (-not $mode) { $mode = if ($url) { "external" } else { "off (or set in the portal)" } }
        "  {0,-9} {1}{2}" -f $m.ToLower(), $mode, $(if ($url) { "  $url" } else { "" })
    }
    "  (the Modules page in the portal can override these)"
}

switch ($Command) {
    "status" {
        Need-Runtime
        Say "Containers"; Compose ps
        Say "Portal"
        if (Test-Portal) { Ok "http://localhost:$Port answers" } else { Bad "http://localhost:$Port does not answer (.\manage.ps1 logs frontend backend)" }
        Say "Modules (from .env)"; Show-Modules
    }
    "start" { Need-Runtime; if ($Rest.Count) { Compose start @Rest } else { Compose up -d } }
    "stop" { Need-Runtime; Compose stop @Rest }
    "restart" { Need-Runtime; Compose restart @Rest }
    "logs" { Need-Runtime; Compose logs -f --tail 200 @Rest }
    "doctor" {
        $problems = -not (Test-Host $Root)
        if (Find-Runtime) {
            Say "Stack"
            $ErrorActionPreference = "Continue"
            $unhealthy = (& $script:E compose ps 2>$null | Out-String) -split "`n" | Where-Object { $_ -match 'unhealthy|Exited|Restarting' }
            $ErrorActionPreference = "Stop"
            if ($unhealthy) { Bad "Not healthy:"; $unhealthy | ForEach-Object { "      $_" }; $problems = $true } else { Ok "Every container is running" }
            if (Test-Portal) { Ok "Portal answers on port $Port" } else { Bad "Portal does not answer on port $Port"; $problems = $true }
        }
        $project = Get-Env DBT_PROJECT_PATH
        if ($project) {
            $full = if ([IO.Path]::IsPathRooted($project)) { $project } else { Join-Path $Root $project }
            if (Test-Path (Join-Path $full "dbt_project.yml")) { Ok "dbt project: $project" } else { Bad "No dbt_project.yml in $project"; $problems = $true }
            if (-not (Test-Path (Join-Path $full ".env"))) { Warn "$project\.env is missing: no warehouse credentials." }
        }
        ""
        if (-not $problems) { Ok "No problems found." }
        else { "Fixes: .\manage.ps1 logs <service>   .\manage.ps1 restart <service>   docs: README.md, 'Troubleshooting'"; exit 1 }
    }
    "upgrade" {
        $release = if ($Rest.Count) { $Rest[0] } else { "latest" }
        $project = Get-Env DBT_PROJECT_PATH
        Say "Upgrading to $release (accounts, history and settings are kept)"
        if ($project) {
            if (-not [IO.Path]::IsPathRooted($project)) { $project = (Resolve-Path (Join-Path $Root $project)).Path }
            & (Join-Path $PSScriptRoot "setup.ps1") -Project $project -Release $release -NonInteractive
        } else {
            & (Join-Path $PSScriptRoot "setup.ps1") -Release $release -NonInteractive
        }
    }
    "backup" {
        Need-Runtime
        New-Item -ItemType Directory -Force backups | Out-Null
        $file = "backups\portal-$(Get-Date -Format yyyyMMdd-HHmmss).sql"
        Say "Dumping the portal databases to $file"
        $ErrorActionPreference = "Continue"
        & $script:E compose exec -T postgres pg_dumpall -U portal | Out-File -Encoding utf8 $file
        if ($LASTEXITCODE -ne 0) { Fail "pg_dumpall failed." }
        Ok "$([math]::Round((Get-Item $file).Length / 1MB, 1)) MB written. Restore: Get-Content $file | $script:E compose exec -T postgres psql -U portal -d postgres"
    }
    "services" {
        @"
  frontend    the web app and the gateway to the API (the only published port)
  backend     the portal API: sign-in, dbt runs and logs, schedules, editor,
              reports, Ask AI, the semantic layer, Airflow/Airbyte, modules
  worker      runs the dbt jobs the backend queues (scale: setup.ps1 -Workers N)
  cube        the semantic layer engine (Cube)
  postgres    the portal's database
  redis       job queue and live logs
  upgrade     one-off at start: moves data from a portal before 2026.11
"@
    }
    "reset-password" {
        Need-Runtime
        $user = if ($Rest.Count) { $Rest[0] } else { "admin" }
        $ErrorActionPreference = "Continue"
        Say "A new password for $user"
        & $script:E compose exec -T backend python -m app.reset_password $user
        if ($LASTEXITCODE -ne 0) { Fail "Could not reset the password (see above)." }
    }
    { $_ -in "help", "-h", "--help" } { Get-Content $PSCommandPath -TotalCount 11 | ForEach-Object { $_ -replace '^# ?', '' } }
    default { Fail "Unknown command '$Command'. Run .\manage.ps1 help" }
}
