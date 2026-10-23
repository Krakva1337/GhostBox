@echo off
setlocal
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  set "POWERSHELL=pwsh.exe"
) else (
  where powershell.exe >nul 2>nul
  if errorlevel 1 (
    echo PowerShell was not found. Install Windows PowerShell 5.1 or PowerShell 7.
    pause
    exit /b 1
  )
  set "POWERSHELL=powershell.exe"
)

"%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\build_windows.ps1" %*
set "BUILD_EXIT=%errorlevel%"
if not "%BUILD_EXIT%"=="0" (
  echo.
  echo GhostBox Windows build failed with exit code %BUILD_EXIT%.
  pause
  exit /b %BUILD_EXIT%
)

echo.
echo GhostBox Windows build completed. Check the dist folder for the ZIP and installer.
pause
exit /b 0
