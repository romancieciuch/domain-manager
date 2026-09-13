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
$iisStartMode = if ($null -ne $iisService) { (Get-CimInstance Win32_Service -Filter "Name='W3SVC'").StartMode } else { $null }
$apacheWasRunning = $apacheService.Status -eq 'Running'

if (-not (Test-Path -LiteralPath $httpdPath -PathType Leaf)) { throw "Nie znaleziono Apache: $httpdPath" }
if (-not $PSCmdlet.ShouldProcess('IIS oraz usługi Domain Manager', 'Ustawienie Domain Managera jako domyślnego serwera po starcie Windows')) { return }

function Set-StartMode {
    param([string] $Name, [ValidateSet('auto', 'delayed-auto', 'demand', 'disabled')] [string] $Mode)
    & "$env:SystemRoot\System32\sc.exe" config $Name "start=" $Mode | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Nie można ustawić trybu startu usługi $Name." }
}

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
    Write-Warning 'Konfiguracja autostartu nie powiodła się. Przywracam poprzedni stan IIS.'
    Stop-Service $ApacheServiceName -Force -ErrorAction SilentlyContinue
    if ($null -ne $iisService) {
        $restoreMode = switch ($iisStartMode) { 'Auto' { 'auto' } 'Disabled' { 'disabled' } default { 'demand' } }
        Set-StartMode -Name W3SVC -Mode $restoreMode
        if ($iisWasRunning) { Start-Service W3SVC -ErrorAction SilentlyContinue }
    }
    if ($apacheWasRunning) { Start-Service $ApacheServiceName -ErrorAction SilentlyContinue }
    throw
}
