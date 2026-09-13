#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $RuntimeConfiguration = (Join-Path $PSScriptRoot 'config\runtime.json'),
    [switch] $RemoveApplicationData,
    [switch] $RemoveApacheService,
    [switch] $EnableIis
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string] $Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }

function Assert-ChildPath {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Parent)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if (-not $fullPath.StartsWith($fullParent + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Odmowa usunięcia ścieżki spoza oczekiwanego katalogu: $fullPath"
    }
    return $fullPath
}

function Remove-DirectoryIfPresent {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Parent)
    $safePath = Assert-ChildPath -Path $Path -Parent $Parent
    if (Test-Path -LiteralPath $safePath) {
        Remove-Item -LiteralPath $safePath -Recurse -Force
    }
}

$runtimePath = [IO.Path]::GetFullPath($RuntimeConfiguration)
if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
    throw "Brakuje konfiguracji środowiska: $runtimePath"
}
$runtime = Get-Content -Raw -LiteralPath $runtimePath | ConvertFrom-Json -Depth 20
if ($runtime.schema_version -ne 1 -or $runtime.platform -ne 'windows') {
    throw 'runtime.json musi mieć schema_version 1 i platformę windows.'
}
$apacheServiceName = [string]$runtime.apache.service_name
if ($apacheServiceName -notmatch '^[A-Za-z0-9._-]+$') { throw 'Nieprawidłowa nazwa usługi Apache.' }
$apacheRoot = [IO.Path]::GetFullPath([string]$runtime.apache.root).TrimEnd('\')
$httpdPath = Join-Path $apacheRoot 'bin\httpd.exe'
$managedConfig = Assert-ChildPath -Path (Join-Path $apacheRoot 'conf\domain-manager') -Parent $apacheRoot
$helperRoot = Assert-ChildPath -Path (Join-Path $env:ProgramFiles 'Domain Manager\Helper') -Parent $env:ProgramFiles
$toolRoot = Assert-ChildPath -Path (Join-Path $env:ProgramFiles 'Domain Manager\Tools') -Parent $env:ProgramFiles
$programDataRoot = Assert-ChildPath -Path (Join-Path $env:ProgramData 'DomainManager') -Parent $env:ProgramData
$caRoot = Assert-ChildPath -Path (Join-Path $programDataRoot 'mkcert') -Parent $programDataRoot
$certificateRoot = Assert-ChildPath -Path (Join-Path $programDataRoot 'certificates') -Parent $programDataRoot
$configRoot = Assert-ChildPath -Path (Join-Path $programDataRoot 'config') -Parent $programDataRoot
$stagingRoot = Assert-ChildPath -Path (Join-Path $programDataRoot 'staging') -Parent $programDataRoot
$backupRoot = Assert-ChildPath -Path (Join-Path $programDataRoot 'backups') -Parent $programDataRoot
$logRoot = Assert-ChildPath -Path (Join-Path $programDataRoot 'logs') -Parent $programDataRoot
$mkcertPath = Join-Path $toolRoot 'mkcert.exe'
$applicationData = Assert-ChildPath -Path (Join-Path $PSScriptRoot 'data') -Parent $PSScriptRoot
$installationStatePath = Join-Path $programDataRoot 'state\installation.json'
$projectStateRoot = Split-Path -Parent $installationStatePath
$installationState = if (Test-Path -LiteralPath $installationStatePath -PathType Leaf) {
    Get-Content -Raw -LiteralPath $installationStatePath | ConvertFrom-Json -Depth 20
} else { $null }
$apacheWasInstalledByDomainManager = $null -ne $installationState -and -not [bool]$installationState.apache_service.exists

$summary = @(
    'usługa i pliki helpera',
    'konfiguracje VirtualHostów Domain Managera',
    'certyfikaty i lokalne CA Domain Managera',
    'chroniona kopia runtime.json, backupy, logi oraz pliki tymczasowe',
    'zainstalowana kopia mkcert.exe'
)
if ($RemoveApplicationData) { $summary += "baza i dane aplikacji: $applicationData" }
if ($RemoveApacheService -or $apacheWasInstalledByDomainManager) { $summary += "usługa Apache: $apacheServiceName (pliki Apache pozostaną)" }
if ($EnableIis) { $summary += 'włączenie i uruchomienie usługi IIS W3SVC' }

Write-Host 'Do usunięcia:' -ForegroundColor Yellow
$summary | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
Write-Host 'Katalogi źródłowe projektów nie zostaną usunięte.' -ForegroundColor Green
if ($WhatIfPreference) {
    Write-Host "`nTryb WhatIf: zakończono przed pierwszą zmianą systemu." -ForegroundColor Cyan
    return
}
if (-not $PSCmdlet.ShouldProcess('komponenty Domain Managera w Windows', 'Deinstalacja')) { return }

Write-Step 'Zatrzymuję usługi'
$apache = Get-Service -Name $apacheServiceName -ErrorAction SilentlyContinue
$apacheWasRunning = $null -ne $apache -and $apache.Status -ne 'Stopped'
if ($apacheWasRunning) {
    Stop-Service -Name $apacheServiceName -Force
    (Get-Service -Name $apacheServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
}
$helper = Get-Service -Name DomainManagerHelper -ErrorAction SilentlyContinue
if ($null -ne $helper) {
    if ($helper.Status -ne 'Stopped') {
        Stop-Service -Name DomainManagerHelper -Force
        $helper.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    }
    & "$env:SystemRoot\System32\sc.exe" delete DomainManagerHelper | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Nie udało się usunąć usługi DomainManagerHelper.' }
}

Write-Step 'Usuwam zaufanie lokalnego CA'
if ((Test-Path -LiteralPath $mkcertPath -PathType Leaf) -and (Test-Path -LiteralPath $caRoot -PathType Container)) {
    $rootCaPath = Join-Path $caRoot 'rootCA.pem'
    $rootCaThumbprint = if (Test-Path -LiteralPath $rootCaPath -PathType Leaf) {
        ([Security.Cryptography.X509Certificates.X509Certificate2]::new($rootCaPath)).Thumbprint
    } else { $null }
    $previousCaroot = [Environment]::GetEnvironmentVariable('CAROOT', 'Process')
    [Environment]::SetEnvironmentVariable('CAROOT', $caRoot, 'Process')
    try {
        & $mkcertPath -uninstall
        if ($LASTEXITCODE -ne 0) { throw "mkcert -uninstall zakończył się kodem $LASTEXITCODE." }
    } finally {
        [Environment]::SetEnvironmentVariable('CAROOT', $previousCaroot, 'Process')
    }
    if ($null -ne $rootCaThumbprint -and (Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -EQ $rootCaThumbprint)) {
        & "$env:SystemRoot\System32\certutil.exe" -delstore Root $rootCaThumbprint | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Nie udało się usunąć lokalnego CA z magazynu systemowego.' }
    }
}

Write-Step 'Usuwam komponenty Domain Managera'
if (Test-Path -LiteralPath $projectStateRoot -PathType Container) {
    foreach ($projectStatePath in @(Get-ChildItem -LiteralPath $projectStateRoot -Filter 'project-*.json' -File)) {
        $projectState = Get-Content -Raw -LiteralPath $projectStatePath.FullName | ConvertFrom-Json
        $projectRoot = [IO.Path]::GetFullPath([string]$projectState.root_path)
        if (Test-Path -LiteralPath $projectRoot -PathType Container) {
            $projectAcl = Get-Acl -LiteralPath $projectRoot
            $projectAcl.SetSecurityDescriptorSddlForm([string]$projectState.original_acl_sddl)
            Set-Acl -LiteralPath $projectRoot -AclObject $projectAcl
        }
    }
}
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
if (Test-Path -LiteralPath $hostsPath -PathType Leaf) {
    $hostsContents = [IO.File]::ReadAllText($hostsPath)
    $hostsWithoutManagedProjects = [regex]::Replace(
        $hostsContents,
        '(?ms)^# BEGIN Domain Manager project:\d+\r?\n.*?^# END Domain Manager project:\d+\r?\n?',
        ''
    ).TrimEnd("`r", "`n") + "`r`n"
    if ($hostsWithoutManagedProjects -ne $hostsContents) {
        [IO.File]::WriteAllText($hostsPath, $hostsWithoutManagedProjects, [Text.UTF8Encoding]::new($false))
    }
}
Remove-DirectoryIfPresent -Path $managedConfig -Parent $apacheRoot
Remove-DirectoryIfPresent -Path $helperRoot -Parent $env:ProgramFiles
Remove-DirectoryIfPresent -Path $toolRoot -Parent $env:ProgramFiles
Remove-DirectoryIfPresent -Path $certificateRoot -Parent $programDataRoot
Remove-DirectoryIfPresent -Path $caRoot -Parent $programDataRoot
Remove-DirectoryIfPresent -Path $configRoot -Parent $programDataRoot
Remove-DirectoryIfPresent -Path $stagingRoot -Parent $programDataRoot
Remove-DirectoryIfPresent -Path $backupRoot -Parent $programDataRoot
Remove-DirectoryIfPresent -Path $logRoot -Parent $programDataRoot
if ($RemoveApplicationData) {
    Remove-DirectoryIfPresent -Path $applicationData -Parent $PSScriptRoot
}

if (($RemoveApacheService -or $apacheWasInstalledByDomainManager) -and $null -ne (Get-Service -Name $apacheServiceName -ErrorAction SilentlyContinue)) {
    Write-Step "Usuwam usługę Apache $apacheServiceName"
    & $httpdPath -k uninstall -n $apacheServiceName
    if ($LASTEXITCODE -ne 0) { throw 'Nie udało się usunąć usługi Apache.' }
} elseif ($null -ne $installationState -and [bool]$installationState.apache_service.exists) {
    Write-Step 'Przywracam konfigurację, ACL-e i usługę Apache'
    if ($null -ne $installationState.httpd_config_base64) {
        [IO.File]::WriteAllBytes([string]$installationState.httpd_config_path, [Convert]::FromBase64String([string]$installationState.httpd_config_base64))
    }
    foreach ($entry in @($installationState.runtime_acls)) {
        if (Test-Path -LiteralPath ([string]$entry.path) -PathType Container) {
            $acl = Get-Acl -LiteralPath ([string]$entry.path)
            $acl.SetSecurityDescriptorSddlForm([string]$entry.sddl)
            Set-Acl -LiteralPath ([string]$entry.path) -AclObject $acl
        }
    }
    if ($null -ne $installationState.apache_service.account) {
        & "$env:SystemRoot\System32\sc.exe" config $apacheServiceName 'obj=' ([string]$installationState.apache_service.account) | Out-Null
    }
    if ($null -ne $installationState.apache_service.sid_type) {
        & "$env:SystemRoot\System32\sc.exe" sidtype $apacheServiceName ([string]$installationState.apache_service.sid_type) | Out-Null
    }
    $startMode = if ([bool]$installationState.apache_service.delayed) { 'delayed-auto' } else { switch ([int]$installationState.apache_service.start) { 2 { 'auto' } 3 { 'demand' } 4 { 'disabled' } default { 'demand' } } }
    & "$env:SystemRoot\System32\sc.exe" config $apacheServiceName 'start=' $startMode | Out-Null
    & $httpdPath -t
    if ($LASTEXITCODE -ne 0) { throw 'Odtworzona konfiguracja Apache jest nieprawidłowa.' }
    if ([bool]$installationState.apache_service.running) {
        Start-Service -Name $apacheServiceName
        (Get-Service -Name $apacheServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    }
} elseif ($apacheWasRunning -and $null -ne (Get-Service -Name $apacheServiceName -ErrorAction SilentlyContinue)) {
    Write-Step 'Uruchamiam ponownie Apache bez konfiguracji Domain Managera'
    & $httpdPath -t
    if ($LASTEXITCODE -ne 0) { throw 'Konfiguracja Apache jest nieprawidłowa po usunięciu VirtualHostów.' }
    Start-Service -Name $apacheServiceName
    (Get-Service -Name $apacheServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
}

if ($EnableIis) {
    Write-Step 'Włączam IIS'
    & "$env:SystemRoot\System32\sc.exe" config W3SVC 'start=' demand | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Nie udało się ustawić ręcznego startu IIS.' }
    Start-Service -Name W3SVC
} elseif ($null -ne $installationState -and [bool]$installationState.iis_service.exists) {
    Write-Step 'Przywracam stan IIS sprzed instalacji'
    $iisStartMode = if ([bool]$installationState.iis_service.delayed) { 'delayed-auto' } else { switch ([int]$installationState.iis_service.start) { 2 { 'auto' } 3 { 'demand' } 4 { 'disabled' } default { 'demand' } } }
    & "$env:SystemRoot\System32\sc.exe" config W3SVC 'start=' $iisStartMode | Out-Null
    if ([bool]$installationState.iis_service.running) { Start-Service -Name W3SVC }
}

Remove-DirectoryIfPresent -Path $projectStateRoot -Parent $programDataRoot
if ((Test-Path -LiteralPath $programDataRoot -PathType Container) -and -not (Get-ChildItem -LiteralPath $programDataRoot -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $programDataRoot -Force
}

Write-Host "`nDomain Manager został odinstalowany. Katalogi projektów pozostały bez zmian." -ForegroundColor Green
if (-not $RemoveApplicationData) { Write-Host "Zachowano dane aplikacji: $applicationData" }
