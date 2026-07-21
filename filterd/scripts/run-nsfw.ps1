# Start filterd with filterd/nsfw.txt.
#
# Dev (browser NOT filtered):
#   .\run-nsfw.ps1
#
# Browser / whole-machine protection (Administrator):
#   .\run-nsfw.ps1 -Protect

param(
    [switch]$Protect,
    [switch]$SystemDNS,
    [switch]$Lockdown,
    [string]$Listen = ""
)

$ErrorActionPreference = "Stop"

$filterdDir = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $filterdDir "filterd.exe"
$nsfw = Join-Path $filterdDir "nsfw.txt"
$allow = Join-Path $filterdDir "allowlist.txt"

if (-not (Test-Path $nsfw)) {
    Write-Error "nsfw.txt not found at $nsfw"
}

Set-Location $filterdDir
if (-not (Test-Path $exe)) {
    Write-Host "Building filterd.exe ..."
    go build -o filterd.exe ./cmd/filterd
}

$argList = [System.Collections.Generic.List[string]]::new()
$argList.Add("run")
$argList.AddRange([string[]]@("-lists", $nsfw))
if (Test-Path $allow) {
    $argList.AddRange([string[]]@("-allow", $allow))
}

if ($Protect) {
    $argList.Add("-protect")
} else {
    if ($Listen) { $argList.AddRange([string[]]@("-listen", $Listen)) }
    if ($SystemDNS) { $argList.Add("-system-dns") }
    if ($Lockdown) { $argList.Add("-lockdown") }
}

if (-not $Protect -and -not $SystemDNS) {
    Write-Host ""
    Write-Host "NOTE: Dev mode only. Browsers still use your router DNS and will NOT be blocked." -ForegroundColor Yellow
    Write-Host "      For browser blocking, open an Admin terminal and run:" -ForegroundColor Yellow
    Write-Host "        .\scripts\run-nsfw.ps1 -Protect" -ForegroundColor Yellow
    Write-Host "      Also turn OFF Secure DNS in Chrome/Edge (use 'os default' / system resolver)." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "Starting filterd:"
Write-Host "  list: $nsfw"
Write-Host "  args: $($argList -join ' ')"
Write-Host ""

& $exe @argList
