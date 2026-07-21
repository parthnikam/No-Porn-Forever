<#
.SYNOPSIS
  Build a shippable zip for the hackathon: double-click INSTALL.bat, no Go required on the target PC.

.EXAMPLE
  .\scripts\pack-ship.ps1
  # → dist\NoPornForever-filterd-windows-amd64.zip
#>
$ErrorActionPreference = "Stop"
$filterd = Split-Path $PSScriptRoot -Parent
Set-Location $filterd

Write-Host "Building filterd.exe..."
go test ./...
go build -ldflags "-s -w" -o filterd.exe ./cmd/filterd

$stage = Join-Path $filterd "dist\ship"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage -Force | Out-Null

foreach ($f in @(
    "filterd.exe",
    "nsfw.txt",
    "allowlist.txt",
    "INSTALL.bat",
    "UNINSTALL.bat",
    "README.md",
    "SHIP.md"
  )) {
  $src = Join-Path $filterd $f
  if (Test-Path $src) {
    Copy-Item $src $stage -Force
    Write-Host "  + $f"
  } else {
    Write-Host "  skip missing: $f"
  }
}

$zip = Join-Path $filterd "dist\NoPornForever-filterd-windows-amd64.zip"
New-Item -ItemType Directory -Path (Split-Path $zip) -Force | Out-Null
if (Test-Path $zip) { Remove-Item $zip -Force }

Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -Force
Write-Host ""
Write-Host "Shippable package:"
Write-Host "  $zip"
Write-Host ""
Write-Host "On target PC: unzip → right-click INSTALL.bat → Run as administrator"
Get-Item $zip | Format-List FullName, Length, LastWriteTime
