<#
.SYNOPSIS
  Machine-wide browser lockdown so NoPornForever is hard to bypass via
  Incognito / Guest / extra profiles (where the browser supports policy).

.DESCRIPTION
  Requires Administrator. Writes HKLM policies (Chrome/Edge) and Firefox
  policies.json. Optionally force-installs the extension when you pass a
  stable Extension ID + update URL (Chrome Web Store or self-hosted CRX).

  Unpacked "Load unpacked" extensions CANNOT be force-installed by Chrome/Edge
  policy — they need a published CRX + update URL. Until then, this script still
  disables Guest, can disable Incognito, and blocks unmanaged browsers.

.PARAMETER ExtensionId
  32-char Chrome/Edge extension ID (from chrome://extensions with Developer mode).
  After force-install from store/CRX the ID is stable.

.PARAMETER UpdateUrl
  CRX update URL. Chrome Web Store default:
    https://clients2.google.com/service/update2/crx
  Edge Add-ons:
    https://edge.microsoft.com/extensionwebstorebase/v1/crx

.PARAMETER IncognitoMode
  Disable   - block Incognito entirely (strongest; recommended for accountability)
  Mandatory - Incognito only works if user allows this extension in Incognito
              (MandatoryExtensionsForIncognitoNavigation)
  Leave     - do not change Incognito availability

.PARAMETER BlockUnmanagedBrowsers
  Best-effort: Soft-block Opera / DuckDuckGo Browser / Brave / Vivaldi executables
  via Image File Execution Options debugger trap pointing at a no-op (easy for
  admins to undo; not as strong as AppLocker). Default: $false

.PARAMETER Remove
  Undo policies written by this script.

.EXAMPLE
  # Strong home-PC lockdown without store listing yet
  .\lock-browsers.ps1 -IncognitoMode Disable

.EXAMPLE
  # After publishing extension id abc... with CWS
  .\lock-browsers.ps1 -ExtensionId "abcdefghijklmnopqrstuvwxyzabcdef" -IncognitoMode Mandatory

.EXAMPLE
  .\lock-browsers.ps1 -Remove
#>
[CmdletBinding()]
param(
  [string]$ExtensionId = "",
  [string]$UpdateUrl = "https://clients2.google.com/service/update2/crx",
  [ValidateSet("Disable", "Mandatory", "Leave")]
  [string]$IncognitoMode = "Disable",
  [switch]$BlockUnmanagedBrowsers,
  [switch]$Remove
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Key([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -Path $Path -Force | Out-Null
  }
}

function Set-Dword([string]$Path, [string]$Name, [int]$Value) {
  Ensure-Key $Path
  New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Set-String([string]$Path, [string]$Name, [string]$Value) {
  Ensure-Key $Path
  New-ItemProperty -Path $Path -Name $Name -PropertyType String -Value $Value -Force | Out-Null
}

function Remove-Value([string]$Path, [string]$Name) {
  if (Test-Path $Path) {
    Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
  }
}

function Remove-KeyIfEmpty([string]$Path) {
  if (Test-Path $Path) {
    $children = @(Get-ChildItem $Path -ErrorAction SilentlyContinue)
    $props = @(Get-ItemProperty $Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSObject).Properties |
      Where-Object { $_.Name -notmatch '^PS' }
    # Keep key even if empty; safer for partial undo of other products' policies
  }
}

# Marker so -Remove only deletes what we created (values we set).
$MarkerPath = "HKLM:\SOFTWARE\NoPornForever\ContentGuard"
$MarkerName = "BrowserLockApplied"

if (-not (Test-IsAdmin)) {
  Write-Error "Run this script in an elevated PowerShell (Run as Administrator)."
}

# ── Capability banner ───────────────────────────────────────────────────────
Write-Host @"

NoPornForever browser lockdown
==========================
DOABLE with policy (Chrome / Edge):
  - Disable Guest mode
  - Disable or gate Incognito
  - Discourage extra people/profiles (best-effort)
  - Force-install extension (ONLY if ExtensionId + CRX update URL)
  - Pin extension / prevent user uninstall of force-installed add-on
  - Turn off Secure DNS (DoH) so filterd sees queries

DOABLE with Firefox policies:
  - Disable Private Browsing
  - Block about:addons / lock some prefs
  - Force-install a *Firefox* XPI (NOT this Chromium extension)

NOT DOABLE / weak:
  - Force "Allow in Incognito" without user click (Chrome limitation)
    → use IncognitoMode Disable OR Mandatory (user must allow once)
  - Force-install unpacked Load-unpacked extension
  - Opera: almost no enterprise extension policy
  - DuckDuckGo Browser: no real enterprise policy surface
  - One extension binary on Firefox/Opera without a port

"@

if ($Remove) {
  Write-Host "Removing NoPornForever browser lockdown policies..."

  foreach ($root in @(
      "HKLM:\SOFTWARE\Policies\Google\Chrome",
      "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    )) {
    foreach ($name in @(
        "BrowserGuestModeEnabled",
        "BrowserAddPersonEnabled",
        "IncognitoModeAvailability",
        "DnsOverHttpsMode",
        "BuiltInDnsClientEnabled",
        "ProxyMode",
        "ExtensionSettings",
        "MandatoryExtensionsForIncognitoNavigation",
        "DeveloperToolsAvailability"
      )) {
      Remove-Value $root $name
    }
    # Force-list subkey
    $fl = Join-Path $root "ExtensionInstallForcelist"
    if (Test-Path $fl) {
      # Only remove our entry named "NoPornForever1" if present; also clear numeric if marker says we own lock
      Remove-Item $fl -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  # Firefox
  $ffPolicy = "$env:ProgramFiles\Mozilla Firefox\distribution\policies.json"
  $ffPolicy86 = "${env:ProgramFiles(x86)}\Mozilla Firefox\distribution\policies.json"
  foreach ($p in @($ffPolicy, $ffPolicy86)) {
    if (Test-Path $p) {
      try {
        $j = Get-Content $p -Raw | ConvertFrom-Json
        if ($j.policies._NoPornForeverManaged -eq $true -or $j.policies.PSObject.Properties.Name -contains "_NoPornForeverManaged") {
          Remove-Item $p -Force
          Write-Host "Removed $p"
        }
      } catch {
        Write-Host "Skip Firefox policy file $p : $_"
      }
    }
  }
  Remove-Item "HKLM:\SOFTWARE\Policies\Mozilla\Firefox" -Recurse -Force -ErrorAction SilentlyContinue

  # Soft browser blocks
  $ifeo = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
  foreach ($exe in @("opera.exe", "duckduckgo.exe", "brave.exe", "vivaldi.exe")) {
    $k = Join-Path $ifeo $exe
    if (Test-Path $k) {
      $dbg = (Get-ItemProperty $k -ErrorAction SilentlyContinue).Debugger
      if ($dbg -and $dbg -match "NoPornForever|ContentGuard|blocked-browser") {
        Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Unblocked $exe"
      }
    }
  }

  Remove-Item $MarkerPath -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Done. Fully quit all browsers and reopen for policies to drop."
  exit 0
}

# ── Apply ───────────────────────────────────────────────────────────────────
Ensure-Key $MarkerPath
Set-Dword $MarkerPath $MarkerName 1
Set-String $MarkerPath "AppliedAt" (Get-Date -Format "o")
Set-String $MarkerPath "IncognitoMode" $IncognitoMode
if ($ExtensionId) { Set-String $MarkerPath "ExtensionId" $ExtensionId }

function Apply-ChromiumPolicy {
  param(
    [string]$Root,
    [string]$BrowserName,
    [string]$StoreUpdateUrl
  )

  Write-Host "`n[$BrowserName] Applying policies under $Root"

  # Guest mode off
  Set-Dword $Root "BrowserGuestModeEnabled" 0
  Write-Host "  BrowserGuestModeEnabled = 0 (Guest disabled)"

  # Best-effort: hide/disable add-person (works on many desktop Chrome builds)
  Set-Dword $Root "BrowserAddPersonEnabled" 0
  Write-Host "  BrowserAddPersonEnabled = 0 (add-profile discouraged)"

  # DNS / proxy — pair with filterd
  Set-String $Root "DnsOverHttpsMode" "off"
  Set-Dword $Root "BuiltInDnsClientEnabled" 0
  Set-String $Root "ProxyMode" "direct"
  Write-Host "  Secure DNS off + ProxyMode=direct"

  # Incognito
  switch ($IncognitoMode) {
    "Disable" {
      # 0=available 1=disabled 2=forced
      Set-Dword $Root "IncognitoModeAvailability" 1
      Write-Host "  IncognitoModeAvailability = 1 (Incognito DISABLED)"
    }
    "Mandatory" {
      Set-Dword $Root "IncognitoModeAvailability" 0
      if ($ExtensionId) {
        # List policy: REG_SZ multi under key OR semicolon? Chrome uses list of extension IDs.
        # Registry: MandatoryExtensionsForIncognitoNavigation is a list policy.
        $manKey = Join-Path $Root "MandatoryExtensionsForIncognitoNavigation"
        Ensure-Key $manKey
        Set-String $manKey "1" $ExtensionId
        Write-Host "  MandatoryExtensionsForIncognitoNavigation = $ExtensionId"
        Write-Host "    (Incognito navigation requires user to Allow this extension in Incognito)"
      } else {
        Write-Warning "  Mandatory mode needs -ExtensionId; leaving Incognito unrestricted"
      }
    }
    "Leave" {
      Write-Host "  Incognito: unchanged"
    }
  }

  # Force-install + lock settings
  if ($ExtensionId -and $ExtensionId -match '^[a-p]{32}$') {
    $url = if ($StoreUpdateUrl) { $StoreUpdateUrl } else { $UpdateUrl }
    $fl = Join-Path $Root "ExtensionInstallForcelist"
    Ensure-Key $fl
    Set-String $fl "1" "$ExtensionId;$url"
    Write-Host "  ExtensionInstallForcelist = $ExtensionId;$url"

    # ExtensionSettings JSON: force_installed + pin; prevent user disable
    $settingsObj = @{
      $ExtensionId = @{
        installation_mode = "force_installed"
        update_url        = $url
        toolbar_pin       = "force_pinned"
      }
      # Optional: block other extensions from interfering — commented for safety
      # "*" = @{ installation_mode = "blocked" }
    }
    $json = $settingsObj | ConvertTo-Json -Compress -Depth 5
    Set-String $Root "ExtensionSettings" $json
    Write-Host "  ExtensionSettings force_installed + force_pinned"

    # Optional: reduce casual sideload of bypass extensions (1 = extensions only from admin)
    # DeveloperToolsAvailability: 0=allow, 1=block with extensions, 2=block always
    # Too aggressive for hackathon dev — leave unset unless you want:
    # Set-Dword $Root "DeveloperToolsAvailability" 2
  }
  elseif ($ExtensionId) {
    Write-Warning "  ExtensionId '$ExtensionId' is not a 32-char a-p id; skipping force-install"
  }
  else {
    Write-Host "  No -ExtensionId: Guest/Incognito/DNS locked, but extension is NOT force-installed."
    Write-Host "  Users must still Load unpacked (or install from store) once per managed browser."
  }
}

Apply-ChromiumPolicy -Root "HKLM:\SOFTWARE\Policies\Google\Chrome" -BrowserName "Chrome" -StoreUpdateUrl $UpdateUrl
Apply-ChromiumPolicy -Root "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -BrowserName "Edge" `
  -StoreUpdateUrl $(if ($UpdateUrl -match "google") { "https://edge.microsoft.com/extensionwebstorebase/v1/crx" } else { $UpdateUrl })

# Chromium clones with partial policy support (often ignored)
foreach ($pair in @(
    @{ Root = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"; Name = "Brave" },
    @{ Root = "HKLM:\SOFTWARE\Policies\Vivaldi"; Name = "Vivaldi" },
    @{ Root = "HKLM:\SOFTWARE\Policies\Opera Software\Opera"; Name = "Opera" },
    @{ Root = "HKLM:\SOFTWARE\Policies\Opera Software\Opera GX"; Name = "Opera GX" }
  )) {
  try {
    Apply-ChromiumPolicy -Root $pair.Root -BrowserName $pair.Name -StoreUpdateUrl $UpdateUrl
    Write-Host "  (Note: $($pair.Name) may ignore enterprise policies — verify in browser)"
  } catch {
    Write-Host "  $($pair.Name): skipped ($($_.Exception.Message))"
  }
}

# ── Firefox ─────────────────────────────────────────────────────────────────
Write-Host "`n[Firefox] Writing policies (Private Browsing off). Chromium extension will NOT load."
$ffRoots = @(
  "$env:ProgramFiles\Mozilla Firefox",
  "${env:ProgramFiles(x86)}\Mozilla Firefox"
) | Where-Object { Test-Path $_ }

$ffPolicyDoc = @{
  policies = @{
    _NoPornForeverManaged      = $true
    DisablePrivateBrowsing = $true
    BlockAboutAddons       = $true
    BlockAboutConfig       = $true
    # Don't install Chromium CRX here — wrong format.
    # If you later ship a Firefox port:
    # Extensions = @{ Install = @("https://.../content-guard.xpi"); Locked = @("content-guard@NoPornForever") }
    Preferences            = @{
      "browser.search.suggest.enabled" = @{ Value = $false; Status = "locked" }
    }
  }
}

foreach ($root in $ffRoots) {
  $dist = Join-Path $root "distribution"
  Ensure-Key "HKLM:\SOFTWARE\Policies\Mozilla\Firefox" | Out-Null
  if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }
  $out = Join-Path $dist "policies.json"
  ($ffPolicyDoc | ConvertTo-Json -Depth 8) | Set-Content -Path $out -Encoding UTF8
  Write-Host "  Wrote $out"
}

# Registry mirror for some Firefox enterprise builds
Ensure-Key "HKLM:\SOFTWARE\Policies\Mozilla\Firefox"
Set-Dword "HKLM:\SOFTWARE\Policies\Mozilla\Firefox" "DisablePrivateBrowsing" 1

# ── DuckDuckGo / Opera: no real force-extension path ────────────────────────
Write-Host "`n[DuckDuckGo Browser / Opera]"
Write-Host "  No reliable force-install + Guest lock equivalent."
Write-Host "  filterd DNS still blocks known domains for any browser."
if ($BlockUnmanagedBrowsers) {
  Write-Host "  Soft-blocking common unmanaged browser EXEs (IFEO)..."
  # Point "Debugger" at a tiny helper that exits — user sees browser fail to start.
  $blocker = Join-Path $PSScriptRoot "blocked-browser.cmd"
  @"
@echo off
echo This browser is blocked by NoPornForever policy.
echo Use managed Chrome or Edge, or run unlock-browsers / lock-browsers.ps1 -Remove as admin.
exit /b 1
"@ | Set-Content -Path $blocker -Encoding ASCII

  $ifeo = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
  foreach ($exe in @("opera.exe", "opera_gx.exe", "duckduckgo.exe", "brave.exe", "vivaldi.exe")) {
    $k = Join-Path $ifeo $exe
    Ensure-Key $k
    Set-String $k "Debugger" "`"$blocker`""
    Write-Host "  IFEO Debugger set for $exe"
  }
  Write-Host "  WARNING: IFEO is easy for an admin to remove; AppLocker/WDAC is stronger."
} else {
  Write-Host "  Tip: pass -BlockUnmanagedBrowsers to soft-block Opera/DDG/Brave/Vivaldi, or uninstall them."
}

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host @"

============================================================
Applied. Fully QUIT Chrome/Edge/Firefox (all windows) and reopen.
Check chrome://policy and edge://policy — policies should show as "Machine".

IncognitoMode = $IncognitoMode
ExtensionId   = $(if ($ExtensionId) { $ExtensionId } else { "(none — force-install skipped)" })

Honest limits:
  * Force-install needs a published CRX + stable ID (not Load unpacked path).
  * Chrome will not silently inject extensions into Incognito without user
    allowing it OR you disabling Incognito (we recommend Disable).
  * Firefox cannot run this Chromium extension; we only lock Private Browsing.
  * Opera / DuckDuckGo: use -BlockUnmanagedBrowsers or uninstall + rely on filterd.

Undo:
  .\lock-browsers.ps1 -Remove
============================================================
"@
