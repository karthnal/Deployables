@echo off
setlocal
title w-okada Voice Changer installer
cd /d "%~dp0"
if not exist "%~dp0install-voice-changer.ps1" (
  echo [x] install-voice-changer.ps1 was not found next to this file.
  echo     Keep both files in the same folder.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-voice-changer.ps1" %*
set "RC=%ERRORLEVEL%"
rem The installer pauses by itself and exits with 0 (success) or 10 (handled failure).
rem Any other code means PowerShell itself failed, so keep the window open here.
if not "%RC%"=="0" if not "%RC%"=="10" (
  echo.
  echo [x] PowerShell exited unexpectedly with code %RC%.
  echo     Check %USERPROFILE%\voice-changer-logs for a log file.
  pause
)
endlocal & exit /b %RC%
