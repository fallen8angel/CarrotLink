@echo off
setlocal
chcp 65001 >nul
for %%I in ("%~dp0..\..") do set "PROJECT_ROOT=%%~fI"
echo [CarrotLink] Starting release build + install...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_ROOT%\scripts\build_dev_apk.ps1" -BuildMode release -Install -PromptDevice -NoPause
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" (
  echo Failed: exit code %EXITCODE%
) else (
  echo Done
)
pause
endlocal
