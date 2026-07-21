@echo off
title EasyPeasy filterd — Uninstall
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting Administrator permission...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

echo.
echo  Stopping service and restoring DNS...
echo.

:: Prefer installed binary; fall back to local
set EXE=%ProgramFiles%\EasyPeasy\filterd\filterd.exe
if not exist "%EXE%" set EXE=%~dp0filterd.exe

if not exist "%EXE%" (
  echo filterd.exe not found. Trying to remove service by name only...
  sc stop EasyPeasyFilterd >nul 2>&1
  sc delete EasyPeasyFilterd >nul 2>&1
  echo If DNS is broken, set your adapter DNS back to Automatic (DHCP).
  pause
  exit /b 1
)

"%EXE%" uninstall
echo.
pause
