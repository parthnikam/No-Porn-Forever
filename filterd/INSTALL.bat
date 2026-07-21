@echo off
title EasyPeasy filterd — Install
cd /d "%~dp0"

:: Elevate to Administrator if needed
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting Administrator permission...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

echo.
echo  ============================================
echo   EasyPeasy DNS Filter — one-time install
echo  ============================================
echo.
echo  This will:
echo    - Copy filterd + blocklist to Program Files
echo    - Install Windows service "EasyPeasyFilterd"
echo    - Start protection now
echo    - Auto-start at every boot
echo.
echo  No terminal needed after this.
echo.

if not exist "%~dp0filterd.exe" (
  echo ERROR: filterd.exe not found next to INSTALL.bat
  echo Build it first:  go build -o filterd.exe ./cmd/filterd
  pause
  exit /b 1
)

if not exist "%~dp0nsfw.txt" (
  echo ERROR: nsfw.txt not found next to INSTALL.bat
  pause
  exit /b 1
)

"%~dp0filterd.exe" install
set ERR=%errorlevel%
echo.
if %ERR% neq 0 (
  echo Install failed with code %ERR%.
  pause
  exit /b %ERR%
)

echo.
echo  Done. You can close this window.
echo  Status anytime:  filterd status
echo  Uninstall:       right-click UNINSTALL.bat as Admin
echo.
pause
