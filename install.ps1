# Install the Claude Usage Tracker daemon as a Task Scheduler task (no admin required).
# Uses InteractiveToken logon so no password is stored.
# Usage: .\install.ps1         (install)
#        .\install.ps1 -Remove (uninstall)
param(
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$TaskName  = "ClaudeUsageDaemon"
$DaemonDir = Join-Path $PSScriptRoot "daemon"
$UserId    = "$env:USERDOMAIN\$env:USERNAME"

if ($Remove) {
    Write-Host "=== Removing Claude Usage Tracker ==="
    schtasks /Delete /TN $TaskName /F 2>$null
    Write-Host "Task removed."
    exit 0
}

Write-Host "=== Claude Usage Tracker - Install ==="
Write-Host ""

# Check dependencies
Write-Host "[1/3] Checking dependencies..."
foreach ($cmd in @("node", "pnpm")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "$cmd is required but not found on PATH"
        exit 1
    }
}
$nodeVer = [int]((node --version) -replace 'v(\d+).*','$1')
if ($nodeVer -lt 18) {
    Write-Error "Node 18+ required (found v$nodeVer)"
    exit 1
}
Write-Host "  All dependencies found"
Write-Host ""

# Install npm packages
Write-Host "[2/3] Installing daemon dependencies..."
Push-Location $DaemonDir
pnpm install
Pop-Location
Write-Host ""

# Register task via XML — InteractiveToken means no stored password, no admin needed
Write-Host "[3/3] Registering scheduled task..."

$NodeExe = (Get-Command node).Source
$XmlPath = [System.IO.Path]::GetTempFileName() + ".xml"

# Task XML must be UTF-16 for schtasks
$Xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$UserId</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$UserId</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$NodeExe</Command>
      <Arguments>index.js</Arguments>
      <WorkingDirectory>$DaemonDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

try {
    [System.IO.File]::WriteAllText($XmlPath, $Xml, [System.Text.Encoding]::Unicode)
    schtasks /Create /TN $TaskName /XML $XmlPath /F
    if ($LASTEXITCODE -ne 0) { throw "schtasks failed with exit code $LASTEXITCODE" }
} finally {
    Remove-Item $XmlPath -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== Done! ==="
Write-Host ""
Write-Host "Daemon starts automatically at login."
Write-Host ""
Write-Host "Start now:   schtasks /Run /TN $TaskName"
Write-Host "Stop:        schtasks /End /TN $TaskName"
Write-Host "Status:      schtasks /Query /TN $TaskName /FO LIST"
Write-Host "Uninstall:   .\install.ps1 -Remove"
Write-Host ""
