#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'DomainManagerPostRebootCheck'
$checkScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'post-reboot-check.ps1'))
$resultPath = Join-Path $env:ProgramData 'DomainManager\logs\post-reboot-result.json'
Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute 'C:\Program Files\PowerShell\7\pwsh.exe' -Argument "-NoProfile -File `"$checkScript`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 8)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host 'Jednorazowy test po restarcie został zarejestrowany.' -ForegroundColor Green
