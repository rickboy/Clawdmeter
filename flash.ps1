# Build and flash firmware to the ESP32-S3.
# Usage: .\flash.ps1 [COM port]
param(
    [string]$Port = "COM3"
)

$ErrorActionPreference = "Stop"

$PioExe = "$env:USERPROFILE\.platformio\penv\Scripts\pio.exe"
if (-not (Test-Path $PioExe)) {
    # Fall back to pio on PATH
    $PioExe = "pio"
}

Write-Host "=== Flashing Claude Usage Tracker ==="
Write-Host "Port: $Port"
Write-Host ""

Push-Location "$PSScriptRoot\firmware"
try {
    & $PioExe run -t upload --upload-port $Port
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "=== Done! ==="
