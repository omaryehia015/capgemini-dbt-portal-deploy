# Shared by setup.ps1 and manage.ps1 (dot-sourced, not run). Expects $Root.

function Say($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Warn($text) { Write-Host "WARNING: $text" -ForegroundColor Yellow }
function Fail($text) { Write-Host "ERROR: $text" -ForegroundColor Red; exit 1 }
function Ok($text) { Write-Host "  [ok] $text" -ForegroundColor Green }
function Bad($text) { Write-Host "  [x]  $text" -ForegroundColor Red }

# The core stack needs about this much; Airbyte installed with abctl wants another 8 GB.
$MinRamGb = 6
$MinDiskGb = 10

# Native commands: run quietly, report success. (Windows PowerShell turns their
# stderr into errors, so it is silenced here and checked through the exit code.)
function Try-Run($exe) { $ErrorActionPreference = "Continue"; & $exe @args *> $null; return ($LASTEXITCODE -eq 0) }

# Sets $script:E to docker or podman; $false when neither runs with compose.
function Find-Runtime {
    foreach ($candidate in "docker", "podman") {
        if ((Get-Command $candidate -ErrorAction SilentlyContinue) -and (Try-Run $candidate info) -and (Try-Run $candidate compose version)) {
            $script:E = $candidate; return $true
        }
    }
    return $false
}

function Compose { $ErrorActionPreference = "Continue"; & $script:E compose @args; if ($LASTEXITCODE -ne 0) { Fail "$script:E compose $($args -join ' ') failed." } }

function Install-Hint {
    "Install Docker Desktop (winget install Docker.DockerDesktop) or Podman Desktop (winget install RedHat.Podman-Desktop) with podman-compose (pip install podman-compose), then start it."
}

# Prints the host checklist; returns $false when something blocks the install.
function Test-Host($path) {
    $blocked = $false
    $os = Get-CimInstance Win32_OperatingSystem
    $ram = [math]::Round($os.TotalVisibleMemorySize / 1MB)
    $cpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $drive = (Get-Item $path).PSDrive
    $disk = [math]::Round($drive.Free / 1GB)
    Say "Checking this machine"
    Ok "$($os.Caption), $env:PROCESSOR_ARCHITECTURE, $ram GB RAM, $cpus CPU, $disk GB free on $($drive.Name):"
    if (Find-Runtime) {
        $ver = (& $script:E --version 2>$null | Select-Object -First 1)
        Ok "$ver with compose"
    } else {
        Bad "Docker or Podman with compose is not running"
        Write-Host "    $(Install-Hint)"
        $blocked = $true
    }
    if ($ram -lt $MinRamGb) { Warn "$ram GB of RAM: the portal needs about $MinRamGb GB (Airbyte on this host another 8 GB)." }
    if ($disk -lt $MinDiskGb) { Warn "$disk GB of free disk: the images and databases need about $MinDiskGb GB." }
    return (-not $blocked)
}

# .env is UTF-8. Windows PowerShell's Get-Content reads the ANSI code page, and
# writing that back as UTF-8 grew every non-ASCII character on each write.
function Read-EnvLines($file) {
    if (-not (Test-Path $file)) { return @() }
    return @([IO.File]::ReadAllLines($file, (New-Object Text.UTF8Encoding $false)))
}

function Get-Env($key) {
    $file = Join-Path $Root ".env"
    if (-not (Test-Path $file)) { return "" }
    $line = Read-EnvLines $file | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
    if ($line) { return $line.Substring($key.Length + 1) } else { return "" }
}

function Set-Env($key, $value) {
    $file = Join-Path $Root ".env"
    $lines = Read-EnvLines $file
    $found = $false
    $lines = $lines | ForEach-Object { if ($_ -match "^$key=") { $found = $true; "$key=$value" } else { $_ } }
    if (-not $found) { $lines += "$key=$value" }
    # UTF-8 without BOM: compose reads the first key with a BOM as a different name.
    [IO.File]::WriteAllLines($file, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
}

# Ports: whether something holds one (a program, or a range Windows reserves for
# Hyper-V/WSL), and whether that is this portal (its API answers).
function Test-PortBusy($port) {
    $addresses = @([Net.IPAddress]::Any, [Net.IPAddress]::Loopback)
    if ([Net.Sockets.Socket]::OSSupportsIPv6) { $addresses += [Net.IPAddress]::IPv6Loopback }
    foreach ($address in $addresses) {
        try { $l = New-Object Net.Sockets.TcpListener($address, $port); $l.Start(); $l.Stop() } catch { return $true }
    }
    return $false
}
function Test-PortIsPortal($port) {
    try { return [bool](Invoke-RestMethod -TimeoutSec 3 "http://localhost:$port/api/version").api_version } catch { return $false }
}
# That port when it is free or already the portal, else the next free one.
function Select-Port([int]$port) {
    if (-not (Test-PortBusy $port) -or (Test-PortIsPortal $port)) { return $port }
    for ($p = $port + 1; $p -lt $port + 100; $p++) { if (-not (Test-PortBusy $p)) { return $p } }
    return $port
}

function Wait-Healthy($port) {
    Write-Host -NoNewline "Waiting for the portal"
    for ($i = 0; $i -lt 60; $i++) {
        # The portal itself, not another program on that port.
        if (Test-PortIsPortal $port) { Write-Host ""; return $true }
        Write-Host -NoNewline "."; Start-Sleep -Seconds 5
    }
    Write-Host ""
    return $false
}
