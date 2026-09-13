#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ServiceName = 'DomainManagerApache',

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $ApacheRoot = 'C:\apache\2.4.68',

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string[]] $PhpRoots = @('C:\php\8.5.10')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$apacheRootPath = [IO.Path]::GetFullPath($ApacheRoot).TrimEnd('\')
$httpdPath = Join-Path $apacheRootPath 'bin\httpd.exe'
$httpdConfigPath = Join-Path $apacheRootPath 'conf\httpd.conf'
$managedConfigPath = Join-Path $apacheRootPath 'conf\domain-manager'
$apacheLogsPath = Join-Path $apacheRootPath 'logs'
$serviceAccount = "NT SERVICE\$ServiceName"
$managedInclude = 'IncludeOptional conf/domain-manager/*.conf'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupPath = "$httpdConfigPath.domain-manager-$timestamp.backup"
$originalConfig = $null
$serviceWasRunning = $false
$serviceAccountChanged = $false

function Invoke-Checked {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Polecenie zakończyło się kodem ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Grant-ServiceAccess {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('RX', 'M')] [string] $Permission
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Nie znaleziono ścieżki wymaganej przez usługę: $Path"
    }

    Invoke-Checked -FilePath "$env:SystemRoot\System32\icacls.exe" -Arguments @(
        $Path,
        '/grant',
        "${serviceAccount}:(OI)(CI)$Permission",
        '/T',
        '/C'
    )
}

if (-not (Test-Path -LiteralPath $httpdPath -PathType Leaf)) {
    throw "Nie znaleziono Apache: $httpdPath"
}

if (-not (Test-Path -LiteralPath $httpdConfigPath -PathType Leaf)) {
    throw "Nie znaleziono konfiguracji Apache: $httpdConfigPath"
}

$service = Get-Service -Name $ServiceName -ErrorAction Stop
$serviceWasRunning = $service.Status -eq 'Running'
$serviceConfiguration = & "$env:SystemRoot\System32\sc.exe" qc $ServiceName

if ($LASTEXITCODE -ne 0) {
    throw "Nie można odczytać konfiguracji usługi $ServiceName."
}

if (($serviceConfiguration -join "`n") -notmatch 'SERVICE_START_NAME\s*:\s*LocalSystem') {
    throw "Instalator oczekuje usługi działającej jako LocalSystem. Przerwano bez zmian."
}

if (-not $PSCmdlet.ShouldProcess($ServiceName, 'Ograniczenie konta i uprawnień usługi Apache')) {
    return
}

try {
    if ($serviceWasRunning) {
        Stop-Service -Name $ServiceName -Force
        (Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    }

    $originalConfig = [IO.File]::ReadAllText($httpdConfigPath)
    [IO.File]::WriteAllText($backupPath, $originalConfig, [Text.UTF8Encoding]::new($false))

    if ($originalConfig -notmatch '(?im)^\s*IncludeOptional\s+["'']?conf/domain-manager/\*\.conf["'']?\s*$') {
        $nextConfig = $originalConfig.TrimEnd("`r", "`n") + "`r`n`r`n# Domain Manager managed VirtualHosts`r`n$managedInclude`r`n"
        $stagingPath = "$httpdConfigPath.$timestamp.tmp"
        [IO.File]::WriteAllText($stagingPath, $nextConfig, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $stagingPath -Destination $httpdConfigPath -Force
    }

    New-Item -ItemType Directory -Path $managedConfigPath -Force | Out-Null
    New-Item -ItemType Directory -Path $apacheLogsPath -Force | Out-Null

    Invoke-Checked -FilePath "$env:SystemRoot\System32\sc.exe" -Arguments @('sidtype', $ServiceName, 'unrestricted')
    Invoke-Checked -FilePath "$env:SystemRoot\System32\sc.exe" -Arguments @('config', $ServiceName, 'obj=', $serviceAccount)
    $serviceAccountChanged = $true

    Grant-ServiceAccess -Path $apacheRootPath -Permission RX
    Grant-ServiceAccess -Path $apacheLogsPath -Permission M
    foreach ($phpRoot in $PhpRoots) {
        Grant-ServiceAccess -Path ([IO.Path]::GetFullPath($phpRoot)) -Permission RX
    }

    Invoke-Checked -FilePath $httpdPath -Arguments @('-t')
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))

    Write-Host "Usługa $ServiceName działa jako $serviceAccount." -ForegroundColor Green
    Write-Host "Backup httpd.conf: $backupPath"
}
catch {
    Write-Warning 'Konfiguracja nie powiodła się. Rozpoczynam rollback.'

    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue

    if ($originalConfig -ne $null) {
        [IO.File]::WriteAllText($httpdConfigPath, $originalConfig, [Text.UTF8Encoding]::new($false))
    }

    if ($serviceAccountChanged) {
        & "$env:SystemRoot\System32\sc.exe" config $ServiceName 'obj=' LocalSystem | Out-Null
    }

    if ($serviceWasRunning) {
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    }

    throw
}
