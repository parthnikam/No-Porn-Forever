# Start the local classifier API used by the Chrome extension.
# Usage:  .\run.ps1
# Optional:  .\run.ps1 -Warmup

param(
  [switch]$Warmup
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "Starting NoPornForever classifier API on http://127.0.0.1:8765 ..."
Write-Host "First model load can take 30-90s (GPU recommended)."

if ($Warmup) {
  Start-Job -ScriptBlock {
    Start-Sleep -Seconds 8
    try {
      Invoke-RestMethod -Method POST -Uri "http://127.0.0.1:8765/warmup" -TimeoutSec 600 | Out-Null
      Write-Host "Warmup complete."
    } catch {
      Write-Host "Warmup skipped: $_"
    }
  } | Out-Null
}

python server.py
