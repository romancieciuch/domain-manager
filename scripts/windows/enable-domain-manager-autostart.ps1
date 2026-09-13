#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })] [string] $ApacheRoot = 'C:\apache\2.4.68',
    [ValidatePattern('^[A-Za-z0-9._-]+$')] [string] $ApacheServiceName = 'DomainManagerApache'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$iisService = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
$apacheService = Get-Service -Name $ApacheServiceName -ErrorAction Stop
$helperService = Get-Service -Name DomainManagerHelper -ErrorAction Stop
$httpdPath = Join-Path ([IO.Path]::GetFullPath($ApacheRoot)) 'bin\httpd.exe'
$iisWasRunning = $null -ne $iisService -and $iisService.Status -eq 'Running'
$apacheWasRunning = $apacheService.Status -eq 'Running'
$helperWasRunning = $helperService.Status -eq 'Running'

if (-not (Test-Path -LiteralPath $httpdPath -PathType Leaf)) { throw "Nie znaleziono Apache: $httpdPath" }
if (-not $PSCmdlet.ShouldProcess('IIS oraz usługi Domain Manager', 'Ustawienie Domain Managera jako domyślnego serwera po starcie Windows')) { return }

function Set-StartMode {
    param([string] $Name, [ValidateSet('auto', 'delayed-auto', 'demand', 'disabled')] [string] $Mode)
    & "$env:SystemRoot\System32\sc.exe" config $Name "start=" $Mode | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Nie można ustawić trybu startu usługi $Name." }
}

function Get-StartMode {
    param([string] $Name)
    $serviceKey = Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$Name"
    $delayedProperty = $serviceKey.PSObject.Properties['DelayedAutostart']
    $isDelayed = $null -ne $delayedProperty -and $delayedProperty.Value -eq 1
    if ($serviceKey.Start -eq 2 -and $isDelayed) { return 'delayed-auto' }
    $mode = switch ($serviceKey.Start) {
        2 { 'auto' }
        3 { 'demand' }
        4 { 'disabled' }
        default { throw "Nieobsługiwany tryb startu usługi ${Name}: $($serviceKey.Start)." }
    }
    return $mode
}

$iisStartMode = if ($null -ne $iisService) { Get-StartMode -Name W3SVC } else { $null }
$apacheStartMode = Get-StartMode -Name $ApacheServiceName
$helperStartMode = Get-StartMode -Name DomainManagerHelper

try {
    if ($null -ne $iisService) {
        if ($iisService.Status -ne 'Stopped') {
            Stop-Service -Name W3SVC -Force
            (Get-Service W3SVC).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
        }
        Set-StartMode -Name W3SVC -Mode disabled
    }

    Set-StartMode -Name DomainManagerHelper -Mode auto
    Set-StartMode -Name $ApacheServiceName -Mode delayed-auto

    if ((Get-Service DomainManagerHelper).Status -ne 'Running') {
        Start-Service DomainManagerHelper
        (Get-Service DomainManagerHelper).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    }

    & $httpdPath -t
    if ($LASTEXITCODE -ne 0) { throw 'Test konfiguracji Apache nie powiódł się.' }
    if ((Get-Service $ApacheServiceName).Status -ne 'Running') {
        Start-Service $ApacheServiceName
        (Get-Service $ApacheServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    }

    $response = Invoke-WebRequest -Uri 'http://domain-manager.localhost/' -UseBasicParsing -TimeoutSec 15
    if ($response.StatusCode -ne 200 -or $response.Content -notmatch '<title>Domain Manager</title>') {
        throw 'Port 80 odpowiada, ale odpowiedź nie pochodzi z Domain Managera.'
    }

    Write-Host 'Domain Manager uruchamia się teraz automatycznie wraz z Windows.' -ForegroundColor Green
    Write-Host 'Usługa WWW IIS (W3SVC) została wyłączona; pozostałe składniki IIS nie zostały odinstalowane.'
}
catch {
    Write-Warning 'Konfiguracja autostartu nie powiodła się. Przywracam poprzedni stan usług.'
    Stop-Service -Name $ApacheServiceName -Force -ErrorAction SilentlyContinue
    Stop-Service -Name DomainManagerHelper -Force -ErrorAction SilentlyContinue

    Set-StartMode -Name $ApacheServiceName -Mode $apacheStartMode
    Set-StartMode -Name DomainManagerHelper -Mode $helperStartMode
    if ($null -ne $iisService) {
        Set-StartMode -Name W3SVC -Mode $iisStartMode
        if ($iisWasRunning) { Start-Service W3SVC -ErrorAction SilentlyContinue }
    }
    if ($apacheWasRunning) { Start-Service $ApacheServiceName -ErrorAction SilentlyContinue }
    if ($helperWasRunning) { Start-Service DomainManagerHelper -ErrorAction SilentlyContinue }
    throw
}
