<#
.SYNOPSIS
  One-time install: register NoPornForever Classifier API to start at every logon.

.DESCRIPTION
  Creates a Windows Scheduled Task "NoPornForeverClassifierAPI" that launches
  launch.py with your Python (conda py3.10 recommended). Models stay warm for
  the Chrome extension at http://127.0.0.1:8765

  Requires: Python env with torch/transformers/fastapi already installed
  (pip install -r requirements.txt in that env).

.PARAMETER PythonExe
  Full path to python.exe. Default: auto-detect miniconda py3.10, else `python`.

.PARAMETER NoWarmup
  Skip background model warmup after start.

.PARAMETER StartNow
  Start the task immediately after register (default: true).

.EXAMPLE
  # Admin or normal user (task runs as current user — better for GPU)
  .\install.ps1

  .\install.ps1 -PythonExe "C:\Users\you\miniconda3\envs\py3.10\python.exe"
#>
[CmdletBinding()]
param(
  [string]$PythonExe = "",
  [switch]$NoWarmup,
  [switch]$NoStart,
  [switch]$Remove
)

$ErrorActionPreference = "Stop"
$TaskName = "NoPornForeverClassifierAPI"
$ApiDir = $PSScriptRoot
$LaunchPy = Join-Path $ApiDir "launch.py"
$DataDir = Join-Path $env:ProgramData "NoPornForever\classifier-api"

function Find-Python {
  if ($PythonExe -and (Test-Path $PythonExe)) { return (Resolve-Path $PythonExe).Path }

  $candidates = @(
    "$env:USERPROFILE\miniconda3\envs\py3.10\python.exe",
    "$env:USERPROFILE\anaconda3\envs\py3.10\python.exe",
    "C:\Users\108pa\miniconda3\envs\py3.10\python.exe",
    "$env:LOCALAPPDATA\miniconda3\envs\py3.10\python.exe",
    "$env:ProgramData\miniconda3\envs\py3.10\python.exe"
  )
  foreach ($c in $candidates) {
    if (Test-Path $c) { return $c }
  }
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "Could not find python.exe. Pass -PythonExe full\path\to\python.exe"
}

if ($Remove) {
  Write-Host "Removing scheduled task $TaskName ..."
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Stopping any process on port 8765..."
  Get-NetTCPConnection -LocalPort 8765 -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique |
    ForEach-Object { if ($_ -and $_ -ne 0) { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }
  Write-Host "Done. (Logs under $DataDir kept)"
  exit 0
}

if (-not (Test-Path $LaunchPy)) {
  throw "launch.py not found at $LaunchPy"
}

$py = Find-Python
Write-Host "Python: $py"
Write-Host "API dir: $ApiDir"

# Sanity: can import fastapi?
& $py -c "import fastapi, uvicorn, torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available())"
if ($LASTEXITCODE -ne 0) {
  throw "Python env missing deps. Run: pip install -r requirements.txt (and torch)"
}

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$config = @{
  python_exe = $py
  api_dir    = $ApiDir
  repo_root  = (Split-Path $ApiDir -Parent)
  warmup     = -not $NoWarmup
  host       = "127.0.0.1"
  port       = 8765
  installed  = (Get-Date -Format "o")
}
$configPath = Join-Path $DataDir "config.json"
$config | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
Write-Host "Wrote $configPath"

# Remove old task if present
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# Action: pythonw preferred for no console flash; fall back to python
$pyw = $py -replace 'python\.exe$', 'pythonw.exe'
if (-not (Test-Path $pyw)) { $pyw = $py }

$arg = "`"$LaunchPy`""
$action = New-ScheduledTaskAction -Execute $pyw -Argument $arg -WorkingDirectory $ApiDir

# At every user logon (user session → CUDA + HuggingFace cache work correctly).
# LocalSystem services often cannot see the GPU, so we intentionally use a
# logon task instead of a classic Windows service.
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -RestartCount 5 `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -MultipleInstances IgnoreNew

# Run as current user so CUDA / HF cache work; Highest for fewer UAC issues on bind
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $triggerLogon `
  -Settings $settings `
  -Principal $principal `
  -Description "NoPornForever local ML API (text+image) for NoPornForever extension on 127.0.0.1:8765" `
  -Force | Out-Null

Write-Host "Registered scheduled task: $TaskName"
Write-Host "  Trigger: At logon (current user — GPU-friendly)"
Write-Host "  Restart on failure: 5 times / 1 min"

if (-not $NoStart) {
  Write-Host "Starting now..."
  Start-ScheduledTask -TaskName $TaskName
  Start-Sleep -Seconds 3

  $ok = $false
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $h = Invoke-RestMethod "http://127.0.0.1:8765/health" -TimeoutSec 2
      if ($h.ok) {
        Write-Host "API online: $($h | ConvertTo-Json -Compress)"
        $ok = $true
        break
      }
    } catch {
      Start-Sleep -Seconds 2
    }
  }
  if (-not $ok) {
    Write-Host "API not responding yet (models may still be loading). Check:"
    Write-Host "  $DataDir\classifier-api.log"
    Write-Host "  Task Scheduler → $TaskName"
  }
}

Write-Host ""
Write-Host "Install complete. The API will start at every logon."
Write-Host "Health:  http://127.0.0.1:8765/health"
Write-Host "Logs:    $DataDir\classifier-api.log"
Write-Host "Remove:  .\install.ps1 -Remove   or UNINSTALL.bat"
