# Take a screenshot from the Waveshare AMOLED display via LVGL snapshot.
# Usage: .\screenshot.ps1 [output.png] [COM port]
param(
    [string]$Output = "screenshot.png",
    [string]$Port   = "COM3"
)

$ErrorActionPreference = "Stop"

$TmpRaw = [System.IO.Path]::GetTempFileName()
$PyFile = [System.IO.Path]::GetTempFileName() + ".py"

try {
    Write-Host "Taking screenshot from $Port..."

    @'
import serial, sys

port_path, raw_path = sys.argv[1], sys.argv[2]
port = serial.Serial(port_path, 115200, timeout=10)
port.reset_input_buffer()
port.write(b"screenshot\n")
port.flush()

while True:
    line = port.readline().decode("utf-8", errors="replace").strip()
    if line.startswith("SCREENSHOT_START"):
        parts = line.split()
        w, h, raw_size = int(parts[1]), int(parts[2]), int(parts[3])
        break
    if line == "SCREENSHOT_ERR":
        print("Device reported screenshot error", file=sys.stderr)
        sys.exit(1)

data = b""
while len(data) < raw_size:
    chunk = port.read(min(4096, raw_size - len(data)))
    if not chunk:
        print(f"Timeout: got {len(data)} of {raw_size} bytes", file=sys.stderr)
        sys.exit(1)
    data += chunk

with open(raw_path, "wb") as f:
    f.write(data)

for _ in range(10):
    line = port.readline().decode("utf-8", errors="replace").strip()
    if line == "SCREENSHOT_END":
        break

port.close()
print(f"Captured {w}x{h} ({len(data)} bytes)")
'@ | Set-Content -Path $PyFile -Encoding UTF8

    python $PyFile $Port $TmpRaw
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Screenshot capture failed"
        exit 1
    }

    ffmpeg -y -f rawvideo -pixel_format rgb565le -video_size 480x480 `
        -i $TmpRaw -update 1 -frames:v 1 $Output 2>$null

    if (Test-Path $Output) {
        Write-Host "Saved: $Output"
    } else {
        Write-Error "Conversion failed"
        exit 1
    }
} finally {
    Remove-Item $TmpRaw, $PyFile -ErrorAction SilentlyContinue
}
