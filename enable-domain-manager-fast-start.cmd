@echo off
setlocal

if /I "%~1"=="--elevated" goto elevated

powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '--elevated' -Verb RunAs"
exit /b %errorlevel%

:elevated
"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -File "%~dp0scripts\windows\enable-domain-manager-autostart.ps1" -Confirm:$false
if errorlevel 1 (
    echo.
    echo Nie udalo sie wlaczyc szybkiego startu Domain Managera.
    pause
    exit /b 1
)

echo.
echo Szybki start Domain Managera zostal wlaczony.
pause
exit /b 0
