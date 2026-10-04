<# : dbt Portal Setup. Double-click to run.
@echo off
setlocal
set "PORTAL_INSTALLER=%~f0"
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "& ([scriptblock]::Create([IO.File]::ReadAllText($env:PORTAL_INSTALLER)))"
exit /b
#>
# ------------------------------------------------------------------------------
# dbt Portal Setup: the window a client runs to install the portal.
#
# It asks for one thing, the access token, then installs with defaults: the
# dbt project is connected later in the portal's Setup Assistant (Git), and the
# install goes to %USERPROFILE%\dbt-portal. "More options" offers a folder on
# this computer and another install location. It starts Docker Desktop or
# Podman when they are installed but not running, runs the client kit's
# setup.ps1 in the background with progress, opens the portal and adds a
# desktop shortcut.
#
# Source of DbtPortalSetup.exe and Install-DbtPortal.cmd: build.ps1 wraps it.
# A copy can carry the token (the line below); otherwise it is pasted in.
# ------------------------------------------------------------------------------
$PrefilledToken = '__PORTAL_TOKEN__'

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$Repo = "omaryehia015/capgemini-dbt-portal-deploy"
$DefaultDir = Join-Path $env:USERPROFILE "dbt-portal"
$Work = Join-Path ([IO.Path]::GetTempPath()) ("dbt-portal-install-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory $Work | Out-Null
$LogFile = Join-Path $Work "install.log"

# -- The background job: runs in its own PowerShell, writes to $LogFile -------
# Lines starting with "##STEP n " move the progress bar; "##NEEDS_RUNTIME"
# means neither Docker nor Podman is installed.
$Job = @'
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Setup's output is UTF-8 (checkmarks); read and write it as such, not the console code page.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$repo = $env:PI_REPO
$dir = $env:PI_DIR
$env:PATH += ";$env:USERPROFILE\bin;C:\Program Files\RedHat\Podman;C:\Program Files\Docker\Docker\resources\bin"
function Step($n, $text) { Write-Output "##STEP $n $text" }
function Quiet($exe) { $ErrorActionPreference = "Continue"; & $exe @args *> $null; return ($LASTEXITCODE -eq 0) }

# 1. Docker or Podman, running
Step 1 "Checking Docker or Podman"
function Running {
    foreach ($e in "docker", "podman") {
        if ((Get-Command $e -ErrorAction SilentlyContinue) -and (Quiet $e info) -and (Quiet $e compose version)) { return $e }
    }
    return $null
}
$engine = Running
if (-not $engine) {
    $desktop = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $desktop) {
        Write-Output "Starting Docker Desktop (this can take a minute)..."
        Start-Process $desktop
    } elseif (Get-Command podman -ErrorAction SilentlyContinue) {
        Write-Output "Starting the Podman machine..."
        Quiet podman machine start | Out-Null
    } else {
        Write-Output "##NEEDS_RUNTIME"
        exit 3
    }
    for ($i = 0; $i -lt 60 -and -not $engine; $i++) { Start-Sleep -Seconds 5; $engine = Running }
    if (-not $engine) { Write-Output "Docker or Podman did not start. Start it, then click Try again."; exit 4 }
}
Write-Output "Using $engine"
# Podman on Windows: the setup runs inside the Podman machine (Linux), with that
# machine's own podman, registry login and paths. Nothing on the Windows side
# (security policy, path translation, compose provider) can get in the way.
$inMachine = $false
if ($engine -eq "podman") { $inMachine = Quiet podman machine inspect }

# 2. The client kit: a release's kit, the newest files (PORTAL_CHANNEL=main),
#    or one already here (PORTAL_KIT_DIR)
# The kit is public: the token is only used to pull the private images.
Step 2 "Downloading the portal"
$tmp = Join-Path $env:PI_WORK "kit"
New-Item -ItemType Directory $tmp -Force | Out-Null
$zip = Join-Path $tmp "kit.zip"
if ($env:PORTAL_KIT_DIR) {
    # A kit already on this computer (offline installs, or testing a new kit).
    $kit = $env:PORTAL_KIT_DIR
    Write-Output "Using the kit in $kit"
} elseif ($env:PORTAL_CHANNEL -eq "main") {
    Invoke-WebRequest -UseBasicParsing -OutFile $zip "https://api.github.com/repos/$repo/zipball/main"
    Expand-Archive $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem $tmp -Directory | Where-Object { Test-Path (Join-Path $_.FullName "compose.yaml") } | Select-Object -First 1
    $kit = Join-Path $tmp "assembled"
    New-Item -ItemType Directory (Join-Path $kit "postgres") -Force | Out-Null
    foreach ($f in "compose.yaml", "compose.single.yaml", ".env.example", "releases.yml") { Copy-Item (Join-Path $src.FullName $f) $kit }
    Copy-Item (Join-Path $src.FullName "postgres\init-databases.sql") (Join-Path $kit "postgres")
    foreach ($f in "setup.sh", "setup.ps1", "manage.sh", "manage.ps1", "lib.sh", "lib.ps1", "install.sh", "install.ps1", "portal.answers.example", "README.md") {
        Copy-Item (Join-Path $src.FullName "deploy\client\$f") $kit
    }
} else {
    $text = (Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/$repo/main/releases.yml").Content
    $release = ([regex]::Match($text, '(?m)^latest:\s*"?([^"\r\n]+)"?')).Groups[1].Value
    if (-not $release) { throw "Could not work out the latest release." }
    $name = "dbt-portal-client-kit-$release"
    Invoke-WebRequest -UseBasicParsing -OutFile $zip "https://github.com/$repo/releases/download/portal-$release/$name.zip"
    Expand-Archive $zip -DestinationPath $tmp -Force
    $kit = Join-Path $tmp $name
    Write-Output "Release $release"
}
if (-not $inMachine) {
    New-Item -ItemType Directory $dir -Force | Out-Null
    # An existing install keeps its .env (secrets, settings): upgrading keeps accounts.
    Get-ChildItem $kit -Force | Where-Object { $_.Name -ne ".env" } | Copy-Item -Destination $dir -Recurse -Force
}

# 3. Install and start
Step 3 "Starting the portal (a few minutes the first time)"
# The port: this install's own (kept when free or already the portal), else the
# first free one from 8080. Checked on Windows, where people open the portal:
# a Windows program on the port would otherwise get the portal's traffic.
function Test-PortBusy($p) {
    $addresses = @([Net.IPAddress]::Any, [Net.IPAddress]::Loopback)
    if ([Net.Sockets.Socket]::OSSupportsIPv6) { $addresses += [Net.IPAddress]::IPv6Loopback }
    foreach ($address in $addresses) {
        try { $l = New-Object Net.Sockets.TcpListener($address, $p); $l.Start(); $l.Stop() } catch { return $true }
    }
    return $false
}
function Test-PortIsPortal($p) {
    try { return [bool](Invoke-RestMethod -TimeoutSec 3 "http://localhost:$p/api/version").api_version } catch { return $false }
}
# The folder shared with the portal, so a dbt project on this computer is linked by
# typing its path in the Setup Assistant: the one chosen under More options, else
# the system drive (C:\) when the install shares nothing yet; an install that
# shares a folder already keeps it.
if ($inMachine) {
    $sharedLine = & podman machine ssh "grep -m1 '^DBT_PROJECTS_ROOT=' ~/dbt-portal/.env 2>/dev/null" 2>$null
} else {
    $sharedLine = Get-Content (Join-Path $dir ".env") -ErrorAction SilentlyContinue | Where-Object { $_ -match '^DBT_PROJECTS_ROOT=' } | Select-Object -First 1
}
$shareRoot = $env:PI_PROJECTS_ROOT
if (-not $shareRoot -and -not ("$sharedLine" -match '^DBT_PROJECTS_ROOT=\S')) { $shareRoot = $env:SystemDrive + "\" }
$current = $null
if ($inMachine) {
    $line = & podman machine ssh "grep -m1 '^PORTAL_PORT=' ~/dbt-portal/.env 2>/dev/null" 2>$null
} else {
    $line = Get-Content (Join-Path $dir ".env") -ErrorAction SilentlyContinue | Where-Object { $_ -match '^PORTAL_PORT=' } | Select-Object -First 1
}
if ("$line" -match 'PORTAL_PORT=(\d+)') { $current = [int]$Matches[1] }
$wanted = if ($current) { $current } else { 8080 }
$port = $wanted
if ((Test-PortBusy $wanted) -and -not (Test-PortIsPortal $wanted)) {
    for ($p = $wanted + 1; $p -lt $wanted + 100; $p++) { if (-not (Test-PortBusy $p)) { $port = $p; break } }
    Write-Output "##NOTE Port $wanted is used by another program, so the portal uses port $port."
}
$script:portalUrl = $null
function Clean($line) {
    $text = if ($line -is [Management.Automation.ErrorRecord]) { $line.Exception.Message } else { "$line" }
    # Colour codes and the empty error records native tools leave behind.
    $text = $text -replace "\x1b\[[0-9;]*m", ""
    if ($text -match 'Portal is up: (http://\S+?)/?$') { $script:portalUrl = $Matches[1] + "/" }
    if ($text -ne "System.Management.Automation.RemoteException") { $text }
}
$ErrorActionPreference = "Continue"
if ($inMachine) {
    # Windows paths as the machine sees them (C:\work -> /mnt/c/work).
    function To-Machine($path) {
        $full = [IO.Path]::GetFullPath($path)
        "/mnt/" + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
    }
    # Moving from a Windows-side install: stop it and bring its .env (same secrets,
    # same compose project name, so accounts and history carry over).
    $oldEnv = ""
    if (Test-Path (Join-Path $dir ".env")) {
        Write-Output "Moving the existing install into the Podman machine"
        Push-Location $dir
        & podman compose down 2>&1 | ForEach-Object { Clean $_ }
        Pop-Location
        $oldEnv = To-Machine (Join-Path $dir ".env")
    }
    $tokenFile = Join-Path $env:PI_WORK "token"
    [IO.File]::WriteAllText($tokenFile, [string]$env:PORTAL_TOKEN)
    $rootArg = ""; $display = ""
    if ($shareRoot) {
        $rootArg = "--projects-root '" + (To-Machine $shareRoot) + "'"
        $display = ([IO.Path]::GetFullPath($shareRoot)) -replace '\\', '/'
    }
    $bash = [IO.File]::ReadAllText((Join-Path $env:PI_WORK "setup-in-machine.template"))
    $bash = $bash.Replace("__OLDENV__", $oldEnv).Replace("__KIT__", (To-Machine $kit)).Replace("__TOKEN__", (To-Machine $tokenFile))
    $bash = $bash.Replace("__DISPLAY__", $display).Replace("__PORT__", "$port").Replace("__ROOTARG__", $rootArg)
    $bashFile = Join-Path $env:PI_WORK "setup-in-machine.sh"
    [IO.File]::WriteAllText($bashFile, ($bash -replace "`r`n", "`n"), (New-Object Text.ASCIIEncoding))
    & podman machine ssh ("bash '" + (To-Machine $bashFile) + "'") 2>&1 | ForEach-Object { Clean $_ }
    $code = $LASTEXITCODE
    Remove-Item $tokenFile, $bashFile -ErrorAction SilentlyContinue
    # Moved for good: the next run must not stop and move it again.
    if ($code -eq 0 -and $oldEnv) { Rename-Item (Join-Path $dir ".env") ".env.moved-to-podman-machine" -Force }
} else {
    # -Release latest: every run installs, or upgrades to, the kit's newest release.
    $setupArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $dir "setup.ps1"), "-NonInteractive", "-NoBrowser", "-Release", "latest")
    if ($shareRoot) { $setupArgs += @("-ProjectsRoot", $shareRoot) }
    $setupArgs += @("-Port", $port)
    & powershell @setupArgs 2>&1 | ForEach-Object { Clean $_ }
    $code = $LASTEXITCODE
}
if ($code -ne 0) { exit $code }

# 4. Shortcuts: the portal opens like any other app
Step 4 "Adding shortcuts"
# The address setup printed ("Portal is up: http://localhost:8080").
$url = if ($script:portalUrl) { $script:portalUrl } else { "http://localhost:$port/" }
$shortcut = "[InternetShortcut]`r`nURL=$url`r`n"
foreach ($folder in [Environment]::GetFolderPath("Desktop"), (Join-Path ([Environment]::GetFolderPath("Programs")) "")) {
    try { [IO.File]::WriteAllText((Join-Path $folder "dbt Portal.url"), $shortcut) } catch { }
}
Write-Output "##URL $url"
Write-Output ("##MODE " + $(if ($inMachine) { "machine" } else { "windows" }))
exit 0
'@

# Runs inside the Podman machine (step 3 of the job fills in the __NAMES__).
$MachineScript = @'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.local/bin" "$HOME/dbt-portal"
if ! command -v docker-compose >/dev/null 2>&1; then
    echo "==> Adding docker compose to the Podman machine"
    curl -fsSL -o "$HOME/.local/bin/docker-compose" \
        https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64
    chmod +x "$HOME/.local/bin/docker-compose"
fi
export PODMAN_COMPOSE_PROVIDER="$HOME/.local/bin/docker-compose"
export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
cd "$HOME/dbt-portal"
# An install moving in from the Windows side: its .env, with Linux line ends.
[[ -f .env || -z "__OLDENV__" ]] || tr -d '\r' < "__OLDENV__" > .env
# The kit, keeping this install's .env (secrets, settings).
(cd "__KIT__" && tar --exclude=./.env -cf - .) | tar -xf -
chmod +x ./*.sh
PORTAL_TOKEN="$(cat "__TOKEN__")"; export PORTAL_TOKEN
export PORTAL_PROJECTS_DISPLAY="__DISPLAY__"
port=(--port __PORT__)
# --release latest: every run installs, or upgrades to, the kit's newest release.
./setup.sh --non-interactive --no-browser --release latest "${port[@]}" __ROOTARG__
'@

# -- The window ---------------------------------------------------------------
$blue = [Drawing.Color]::FromArgb(0, 112, 173)
$muted = [Drawing.Color]::FromArgb(91, 107, 120)
$font = New-Object Drawing.Font("Segoe UI", 10)

$form = New-Object Windows.Forms.Form
$form.Text = "dbt Portal Setup"
$form.ClientSize = New-Object Drawing.Size(560, 560)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = $font
$form.BackColor = [Drawing.Color]::White

function New-Label($text, $x, $y, $w, $h, $size = 10, $bold = $false, $color = $null) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object Drawing.Point($x, $y)
    $l.Size = New-Object Drawing.Size($w, $h)
    $style = if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $l.Font = New-Object Drawing.Font("Segoe UI", $size, $style)
    if ($color) { $l.ForeColor = $color }
    return $l
}

$header = New-Object Windows.Forms.Panel
$header.Dock = "Top"
$header.Height = 78
$header.BackColor = $blue
$title = New-Label "dbt Portal" 24 12 500 32 16 $true ([Drawing.Color]::White)
$sub = New-Label "Installs the portal on this computer in about five minutes." 24 44 520 22 10 $false ([Drawing.Color]::White)
$header.Controls.AddRange(@($title, $sub))
$form.Controls.Add($header)

# Page 1: the questions
$ask = New-Object Windows.Forms.Panel
$ask.Location = New-Object Drawing.Point(0, 78)
$ask.Size = New-Object Drawing.Size(560, 482)

$ask.Controls.Add((New-Label "Paste your access token" 24 24 400 24 12 $true))
$ask.Controls.Add((New-Label "The token you were sent. That is all: the rest is set up for you, and the portal guides you once it is running." 24 54 510 40 9 $false $muted))
$tokenBox = New-Object Windows.Forms.TextBox
$tokenBox.Location = New-Object Drawing.Point(24, 98)
$tokenBox.Size = New-Object Drawing.Size(510, 30)
$tokenBox.Font = New-Object Drawing.Font("Segoe UI", 11)
$tokenBox.UseSystemPasswordChar = $true
if ($PrefilledToken -and $PrefilledToken -notlike "__*__") { $tokenBox.Text = $PrefilledToken }
elseif ($env:PORTAL_TOKEN) { $tokenBox.Text = $env:PORTAL_TOKEN }
$ask.Controls.Add($tokenBox)

# More options, closed by default: where the project is, and where to install.
$moreLink = New-Object Windows.Forms.LinkLabel
$moreLink.Text = "More options"
$moreLink.Location = New-Object Drawing.Point(24, 140)
$moreLink.Size = New-Object Drawing.Size(200, 22)
$ask.Controls.Add($moreLink)
$advanced = New-Object Windows.Forms.Panel
$advanced.Location = New-Object Drawing.Point(0, 168)
$advanced.Size = New-Object Drawing.Size(560, 230)
$advanced.Visible = $false
$ask.Controls.Add($advanced)
$moreLink.Add_LinkClicked({ $advanced.Visible = -not $advanced.Visible; Set-Layout $(if ($advanced.Visible) { "options" } else { "token" }) })

$advanced.Controls.Add((New-Label "Your dbt project" 24 0 300 20 10 $true))
$gitRadio = New-Object Windows.Forms.RadioButton
$gitRadio.Text = "In a Git repository: connect it in the portal (default)"
$gitRadio.Location = New-Object Drawing.Point(24, 24)
$gitRadio.Size = New-Object Drawing.Size(510, 24)
$gitRadio.Checked = $true
$folderRadio = New-Object Windows.Forms.RadioButton
$folderRadio.Text = "In a folder on this computer: pick the project in the portal"
$folderRadio.Location = New-Object Drawing.Point(24, 50)
$folderRadio.Size = New-Object Drawing.Size(510, 24)
$folderBox = New-Object Windows.Forms.TextBox
$folderBox.Location = New-Object Drawing.Point(44, 78)
$folderBox.Size = New-Object Drawing.Size(390, 26)
$folderBox.Enabled = $false
$folderButton = New-Object Windows.Forms.Button
$folderButton.Text = "Browse..."
$folderButton.Location = New-Object Drawing.Point(440, 77)
$folderButton.Size = New-Object Drawing.Size(94, 28)
$folderButton.Enabled = $false
$folderHint = New-Label "The folder with your project, or a parent folder that holds several." 44 106 490 20 9 $false $muted
$advanced.Controls.AddRange(@($gitRadio, $folderRadio, $folderBox, $folderButton, $folderHint))
$folderRadio.Add_CheckedChanged({ $folderBox.Enabled = $folderRadio.Checked; $folderButton.Enabled = $folderRadio.Checked })
$folderButton.Add_Click({
    $d = New-Object Windows.Forms.FolderBrowserDialog
    $d.Description = "Choose the folder that holds your dbt project"
    if ($d.ShowDialog($form) -eq "OK") { $folderBox.Text = $d.SelectedPath }
})

$advanced.Controls.Add((New-Label "Install in" 24 140 300 20 10 $true))
$dirBox = New-Object Windows.Forms.TextBox
$dirBox.Location = New-Object Drawing.Point(24, 164)
$dirBox.Size = New-Object Drawing.Size(410, 26)
$dirBox.Text = $DefaultDir
$dirButton = New-Object Windows.Forms.Button
$dirButton.Text = "Browse..."
$dirButton.Location = New-Object Drawing.Point(440, 163)
$dirButton.Size = New-Object Drawing.Size(94, 28)
$dirButton.Add_Click({
    $d = New-Object Windows.Forms.FolderBrowserDialog
    if ($d.ShowDialog($form) -eq "OK") { $dirBox.Text = Join-Path $d.SelectedPath "dbt-portal" }
})
$advanced.Controls.AddRange(@($dirBox, $dirButton))
$advanced.Controls.Add((New-Label "Running setup again later upgrades the portal; accounts and history are kept." 24 196 510 20 9 $false $muted))

$installButton = New-Object Windows.Forms.Button
$installButton.Text = "Install"
$installButton.Location = New-Object Drawing.Point(394, 410)
$installButton.Size = New-Object Drawing.Size(140, 40)
$installButton.BackColor = $blue
$installButton.ForeColor = [Drawing.Color]::White
$installButton.FlatStyle = "Flat"
$installButton.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$ask.Controls.Add($installButton)
$form.AcceptButton = $installButton
$form.Controls.Add($ask)

# Page 2: progress, then the result
$run = New-Object Windows.Forms.Panel
$run.Location = New-Object Drawing.Point(0, 78)
$run.Size = New-Object Drawing.Size(560, 482)
$run.Visible = $false
$stepLabel = New-Label "Starting..." 24 18 510 24 12 $true
$detailLabel = New-Label "" 24 44 510 20 9 $false $muted
$bar = New-Object Windows.Forms.ProgressBar
$bar.Location = New-Object Drawing.Point(24, 70)
$bar.Size = New-Object Drawing.Size(510, 14)
$bar.Maximum = 40
$logBox = New-Object Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$logBox.Font = New-Object Drawing.Font("Consolas", 8.5)
$logBox.Location = New-Object Drawing.Point(24, 98)
$logBox.Size = New-Object Drawing.Size(510, 190)
$logBox.BackColor = [Drawing.Color]::FromArgb(245, 247, 250)
$run.Controls.AddRange(@($stepLabel, $detailLabel, $bar, $logBox))

$doneBox = New-Object Windows.Forms.Panel
$doneBox.Location = New-Object Drawing.Point(24, 300)
$doneBox.Size = New-Object Drawing.Size(510, 170)
$doneBox.Visible = $false
$doneBox.Controls.Add((New-Label "Sign in as admin with this password (shown once):" 0 0 510 20 9 $false $muted))
$passBox = New-Object Windows.Forms.TextBox
$passBox.ReadOnly = $true
$passBox.Font = New-Object Drawing.Font("Consolas", 12)
$passBox.Location = New-Object Drawing.Point(0, 24)
$passBox.Size = New-Object Drawing.Size(380, 28)
$copyButton = New-Object Windows.Forms.Button
$copyButton.Text = "Copy"
$copyButton.Location = New-Object Drawing.Point(390, 23)
$copyButton.Size = New-Object Drawing.Size(120, 30)
$copyButton.Add_Click({ if ($passBox.Text) { [Windows.Forms.Clipboard]::SetText($passBox.Text) } })
$openButton = New-Object Windows.Forms.Button
$openButton.Text = "Open the portal"
$openButton.Location = New-Object Drawing.Point(330, 120)
$openButton.Size = New-Object Drawing.Size(180, 40)
$openButton.BackColor = $blue
$openButton.ForeColor = [Drawing.Color]::White
$openButton.FlatStyle = "Flat"
$openButton.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$doneNote = New-Label "A 'dbt Portal' shortcut is on your desktop. The Setup Assistant takes it from here." 0 60 510 56 9 $false $muted
# Lost the admin password? A new one, shown once, like the first.
$forgotLink = New-Object Windows.Forms.LinkLabel
$forgotLink.Text = "Forgot the admin password? Get a new one"
$forgotLink.Location = New-Object Drawing.Point(0, 126)
$forgotLink.Size = New-Object Drawing.Size(320, 22)
$forgotLink.Visible = $false
$resetAdmin = {
    $form.Cursor = "WaitCursor"
    $forgotLink.Text = "Setting a new password..."
    try {
        $ErrorActionPreference = "Continue"
        if ($state.mode -eq "machine") {
            $out = & podman machine ssh "cd ~/dbt-portal && ./manage.sh reset-password admin" 2>&1 | ForEach-Object { "$_" }
        } else {
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dirBox.Text.Trim() "manage.ps1") reset-password admin 2>&1 | ForEach-Object { "$_" }
        }
        $new = $out | Select-String -Pattern '^\s+admin\s+(\S+)\s*$' | Select-Object -Last 1
        if ($new) {
            $passBox.Text = $new.Matches[0].Groups[1].Value
            $forgotLink.Visible = $false
            $logBox.AppendText("A new admin password was set (shown above, once).`r`n")
        } else {
            $forgotLink.Text = "Could not set a new password: see the log"
            $logBox.AppendText((($out | Select-Object -Last 8) -join "`r`n") + "`r`n")
        }
    } finally { $form.Cursor = "Default" }
}
$forgotLink.Add_LinkClicked($resetAdmin)
$doneBox.Controls.AddRange(@($passBox, $copyButton, $openButton, $doneNote, $forgotLink))

$failBox = New-Object Windows.Forms.Panel
$failBox.Location = New-Object Drawing.Point(24, 300)
$failBox.Size = New-Object Drawing.Size(510, 170)
$failBox.Visible = $false
$failText = New-Label "" 0 0 510 60 10 $false ([Drawing.Color]::FromArgb(180, 35, 24))
$getDocker = New-Object Windows.Forms.LinkLabel
$getDocker.Text = "Download Docker Desktop"
$getDocker.Location = New-Object Drawing.Point(0, 66)
$getDocker.Size = New-Object Drawing.Size(300, 22)
$getDocker.Visible = $false
$getDocker.Add_LinkClicked({ Start-Process "https://www.docker.com/products/docker-desktop/" })
$retryButton = New-Object Windows.Forms.Button
$retryButton.Text = "Try again"
$retryButton.Location = New-Object Drawing.Point(370, 120)
$retryButton.Size = New-Object Drawing.Size(140, 40)
$failBox.Controls.AddRange(@($failText, $getDocker, $retryButton))
$run.Controls.AddRange(@($doneBox, $failBox))
$form.Controls.Add($run)

# -- Running it ---------------------------------------------------------------
$state = @{ proc = $null; read = 0; url = $null; password = $null; runtime = $false; step = 0 }
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 400

function Show-Lines([string[]]$lines) {
    foreach ($line in $lines) {
        if ($line -match '^##STEP (\d) (.*)$') {
            $state.step = [int]$Matches[1]
            $stepLabel.Text = "Step $($Matches[1]) of 4: $($Matches[2])"
            $bar.Value = [Math]::Min($bar.Maximum, ($state.step - 1) * 10 + 1)
            continue
        }
        if ($line -eq "##NEEDS_RUNTIME") { $state.runtime = $true; continue }
        if ($line -match "token cannot download the portal images|did not accept that token") { $state.badToken = $true }
        if ($line -match '^##URL (\S+)') { $state.url = $Matches[1]; continue }
        if ($line -match '^##MODE (\S+)') { $state.mode = $Matches[1]; continue }
        if ($line -match '^##NOTE (.*)$') { $state.note = $Matches[1]; $detailLabel.Text = $Matches[1]; $logBox.AppendText($Matches[1] + "`r`n"); continue }
        if ($line -match '\|\s+admin\s+(\S+)\s*$') { $state.password = $Matches[1] }
        if ($line -match '^==> (.*)$') { $detailLabel.Text = $Matches[1] }
        if ($line.Trim()) { $logBox.AppendText($line + "`r`n") }
        # Creep forward inside a step so long pulls do not look frozen.
        if ($state.step -gt 0 -and $bar.Value -lt $state.step * 10 - 1) { $bar.Value += 1 }
    }
}

$timer.Add_Tick({
    if (Test-Path $LogFile) {
        $fs = [IO.File]::Open($LogFile, "Open", "Read", "ReadWrite")
        try {
            $fs.Seek($state.read, "Begin") | Out-Null
            $reader = New-Object IO.StreamReader($fs)
            $text = $reader.ReadToEnd()
            $state.read = $fs.Position
        } finally { $fs.Dispose() }
        if ($text) { Show-Lines ($text -split "\r?\n") }
    }
    if ($state.proc -and $state.proc.HasExited) {
        $timer.Stop()
        if ($Unattended) {
            if ($env:PORTAL_INSTALL_RESET -eq "1" -and $state.proc.ExitCode -eq 0 -and -not $state.password) {
                & $resetAdmin
                if ($passBox.Text -notmatch '^\(') { $state.password = $passBox.Text }
            }
            if ($env:PORTAL_INSTALL_RESULT) {
                "exit=$($state.proc.ExitCode) url=$($state.url) password_found=$([bool]$state.password)" | Set-Content $env:PORTAL_INSTALL_RESULT
                Copy-Item $LogFile ($env:PORTAL_INSTALL_RESULT + ".log") -ErrorAction SilentlyContinue
            }
            $form.Close()
            return
        }
        if ($state.proc.ExitCode -eq 0) {
            $bar.Value = $bar.Maximum
            $stepLabel.Text = "The portal is running"
            $detailLabel.Text = if ($state.url) { $state.url } else { "" }
            if ($state.password) { $passBox.Text = $state.password }
            else {
                $passBox.Text = "(set earlier: the accounts already exist)"
                $forgotLink.Visible = $true
            }
            if ($state.note) { $doneNote.Text = $state.note + " " + $doneNote.Text }
            $doneBox.Visible = $true
            if ($state.url) { Start-Process ($state.url + "setup") }
        } else {
            $stepLabel.Text = "The install stopped"
            if ($state.badToken) {
                $failText.Text = "This token cannot download the portal. Ask for a new one (a GitHub token, classic, with read:packages), then click Try again and paste it."
            } elseif ($state.runtime) {
                $failText.Text = "The portal runs in Docker. Install Docker Desktop, start it, then click Try again."
                $getDocker.Visible = $true
            } else {
                $failText.Text = "Something went wrong (see the log above). Fix it and click Try again: nothing is lost."
            }
            $failBox.Visible = $true
        }
    }
})

$installButton.Add_Click({
    $token = $tokenBox.Text.Trim()
    if (-not $token) { [Windows.Forms.MessageBox]::Show($form, "Paste the access token you were sent.", "dbt Portal") | Out-Null; return }
    if ($folderRadio.Checked -and -not (Test-Path $folderBox.Text -PathType Container)) {
        [Windows.Forms.MessageBox]::Show($form, "Choose the folder that holds your dbt project.", "dbt Portal") | Out-Null; return
    }
    $jobFile = Join-Path $Work "job.ps1"
    [IO.File]::WriteAllText((Join-Path $Work "setup-in-machine.template"), $MachineScript)
    [IO.File]::WriteAllText($jobFile, $Job)
    if (Test-Path $LogFile) { Remove-Item $LogFile }
    $state.read = 0; $state.url = $null; $state.password = $null; $state.runtime = $false; $state.badToken = $false; $state.note = $null; $state.mode = $null; $state.step = 0; $forgotLink.Visible = $false
    $logBox.Clear(); $bar.Value = 0; $doneBox.Visible = $false; $failBox.Visible = $false; $getDocker.Visible = $false

    $env:PORTAL_TOKEN = $token
    $env:PI_REPO = $Repo
    $env:PI_DIR = $dirBox.Text.Trim()
    $env:PI_WORK = $Work
    $env:PI_PROJECTS_ROOT = if ($folderRadio.Checked) { $folderBox.Text.Trim() } else { "" }
    $state.proc = Start-Process powershell -PassThru -WindowStyle Hidden -RedirectStandardOutput $LogFile `
        -RedirectStandardError (Join-Path $Work "errors.log") `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$jobFile`"")
    # Read the handle now: without it, ExitCode stays empty once the process ends.
    $null = $state.proc.Handle
    $ask.Visible = $false
    Set-Layout "run"
    $run.Visible = $true
    $timer.Start()
})

$retryButton.Add_Click({ $run.Visible = $false; $ask.Visible = $true; Set-Layout $(if ($advanced.Visible) { "options" } else { "token" }) })
$openButton.Add_Click({ if ($state.url) { Start-Process ($state.url + "setup") } })
$form.Add_FormClosing({
    if ($state.proc -and -not $state.proc.HasExited) {
        $answer = [Windows.Forms.MessageBox]::Show($form, "The install is still running. Stop it?", "dbt Portal", "YesNo")
        if ($answer -ne "Yes") { $_.Cancel = $true; return }
        try { $state.proc.Kill() } catch { }
    }
})

# The window is only as tall as what it shows: the token, the options, or the progress.
function Set-Layout($mode) {
    $height = switch ($mode) { "token" { 300 } "options" { 520 } default { 560 } }
    $form.ClientSize = New-Object Drawing.Size(560, $height)
    $ask.Size = New-Object Drawing.Size(560, ($height - 78))
    $installButton.Location = New-Object Drawing.Point(394, ($height - 78 - 62))
}
Set-Layout "token"

# Unattended (PORTAL_INSTALL_UNATTENDED=1): the same window runs on its own and
# closes when it is done, for scripted installs and tests. PORTAL_INSTALL_FOLDER
# shares a project folder, PORTAL_INSTALL_DIR picks the install folder, and
# PORTAL_INSTALL_RESULT is a file that receives the outcome and the log;
# PORTAL_INSTALL_RESET=1 also asks for a new admin password when none was shown.
$Unattended = $env:PORTAL_INSTALL_UNATTENDED -eq "1"
if ($Unattended) {
    if ($env:PORTAL_INSTALL_FOLDER) { $folderRadio.Checked = $true; $folderBox.Text = $env:PORTAL_INSTALL_FOLDER }
    if ($env:PORTAL_INSTALL_DIR) { $dirBox.Text = $env:PORTAL_INSTALL_DIR }
    $form.Add_Shown({ $installButton.PerformClick() })
}

[void]$form.ShowDialog()
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
