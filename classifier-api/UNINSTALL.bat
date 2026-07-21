@echo off
title EasyPeasy Classifier API — Uninstall
cd /d "%~dp0"

echo Removing auto-start task and stopping API...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Remove
echo.
pause
