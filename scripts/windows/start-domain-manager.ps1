#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$iis = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
if ($null -ne $iis -and $iis.Status -eq 'Running') {
    throw 'Usługa WWW IIS (W3SVC) działa i może zajmować port 80. Zatrzymaj ją albo uruchom enable-domain-manager-autostart.ps1.'
}

$listeners = Get-NetTCPConnection -State Listen -LocalPort 80, 443 -ErrorAction SilentlyContinue
$foreign = $listeners | Where-Object {
    $process = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
    $null -ne $process -and $process.ProcessName -notin @('httpd', 'System')
}
if ($foreign) {
    $owners = $foreign | ForEach-Object { (Get-Process -Id $_.OwningProcess).ProcessName } | Sort-Object -Unique
    throw 'Port 80 lub 443 jest zajęty przez: ' + ($owners -join ', ')
}

foreach ($serviceName in @('DomainManagerHelper', 'DomainManagerApache')) {
    if ((Get-Service $serviceName -ErrorAction Stop).Status -ne 'Running') {
        Start-Service $serviceName
        (Get-Service $serviceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    }
}

$response = Invoke-WebRequest -Uri 'http://domain-manager.localhost/' -UseBasicParsing -TimeoutSec 15
if ($response.StatusCode -ne 200 -or $response.Content -notmatch '<title>Domain Manager</title>') {
    throw 'Serwer odpowiada, ale nie zwrócił interfejsu Domain Managera.'
}
Write-Host 'Domain Manager działa: http://domain-manager.localhost/' -ForegroundColor Green
