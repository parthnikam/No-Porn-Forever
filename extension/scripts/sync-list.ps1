# Copy filterd/nsfw.txt into the extension package so Domain Guard can load it.
$ErrorActionPreference = "Stop"
$extDir = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $extDir -Parent
$src = Join-Path $repoRoot "filterd\nsfw.txt"
$dst = Join-Path $extDir "nsfw.txt"

if (-not (Test-Path $src)) {
    Write-Error "Source list not found: $src"
}

Copy-Item -Path $src -Destination $dst -Force
$lines = (Get-Content $dst | Measure-Object -Line).Lines
Write-Host "Synced nsfw.txt → extension\nsfw.txt ($lines lines)"
Write-Host "Reload the extension in chrome://extensions if it is already installed."
