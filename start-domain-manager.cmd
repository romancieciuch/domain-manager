@echo off
setlocal

if /I "%~1"=="--elevated" goto elevated

powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '--elevated' -Verb RunAs"
exit /b %errorlevel%

:elevated
"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -File "%~dp0scripts\windows\start-domain-manager.ps1"
if errorlevel 1 (
    echo.
    echo Nie udalo sie uruchomic Domain Managera.
    pause
    exit /b 1
)

start "" "https://domain-manager.localhost/"
exit /b 0
