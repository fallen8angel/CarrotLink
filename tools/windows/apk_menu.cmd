@echo off
setlocal
chcp 65001 >nul
for %%I in ("%~dp0..\..") do set "PROJECT_ROOT=%%~fI"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_ROOT%\scripts\apk_menu.ps1"
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" (
  echo Menu failed: exit code %EXITCODE%
  pause
)
endlocal
