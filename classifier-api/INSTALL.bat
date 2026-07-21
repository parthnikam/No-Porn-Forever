@echo off
title NoPornForever Classifier API — Install
cd /d "%~dp0"

echo.
echo  ================================================
echo   NoPornForever Classifier API — one-time install
echo  ================================================
echo.
echo  Registers a Windows task so the ML API starts
echo  at every logon on http://127.0.0.1:8765
echo  (required by the NoPornForever extension)
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set ERR=%errorlevel%
echo.
if %ERR% neq 0 (
  echo Install failed with code %ERR%.
  echo If deps are missing:
  echo   conda activate py3.10
  echo   pip install -r requirements.txt
  pause
  exit /b %ERR%
)
echo.
pause
