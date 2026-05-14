# Install the Claude Usage Tracker daemon as a Windows Task Scheduler task.
# Runs at login, restarts on failure. Requires Node 18+.
# Usage: .\install.ps1         (install)
#        .\install.ps1 -Remove (uninstall)
param(
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$TaskName  = "ClaudeUsageDaemon"
$DaemonDir = Join-Path $PSScriptRoot "daemon"

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

# Register Task Scheduler task
Write-Host "[3/3] Registering scheduled task..."

$NodeExe  = (Get-Command node).Source
$Action   = New-ScheduledTaskAction `
    -Execute $NodeExe `
    -Argument "index.js" `
    -WorkingDirectory $DaemonDir

# At logon, any user
$Trigger  = New-ScheduledTaskTrigger -AtLogOn

# Restart up to 3 times on failure, 30s apart
$Settings = New-ScheduledTaskSettingsSet `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Seconds 30) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -RunLevel Limited `
    -Force | Out-Null

Write-Host ""
Write-Host "=== Done! ==="
Write-Host ""
Write-Host "Daemon registered as Task Scheduler task '$TaskName'."
Write-Host "Starts automatically at login."
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Start-ScheduledTask -TaskName $TaskName     # start now"
Write-Host "  Stop-ScheduledTask  -TaskName $TaskName     # stop"
Write-Host "  Get-ScheduledTask   -TaskName $TaskName     # status"
Write-Host "  .\install.ps1 -Remove                       # uninstall"
Write-Host ""
