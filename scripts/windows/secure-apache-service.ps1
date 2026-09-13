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
$serviceSidTypeChanged = $false

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
        [Parameter(Mandatory)] [Security.AccessControl.FileSystemRights] $Rights
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Nie znaleziono ścieżki wymaganej przez usługę: $Path"
    }

    $acl = Get-Acl -LiteralPath $Path
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $serviceAccount,
        $Rights,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Restore-Acls {
    param([Parameter(Mandatory)] [object[]] $Backup)
    foreach ($entry in $Backup) {
        $acl = Get-Acl -LiteralPath $entry.Path
        $acl.SetSecurityDescriptorSddlForm($entry.Sddl)
        Set-Acl -LiteralPath $entry.Path -AclObject $acl
    }
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

$serviceConfigurationText = $serviceConfiguration -join "`n"
$usesLocalSystem = $serviceConfigurationText -match 'SERVICE_START_NAME\s*:\s*LocalSystem'
$usesServiceAccount = $serviceConfigurationText -match "SERVICE_START_NAME\s*:\s*$([regex]::Escape($serviceAccount))"
if (-not $usesLocalSystem -and -not $usesServiceAccount) {
    throw "Usługa $ServiceName działa na nieobsługiwanym koncie. Oczekiwano LocalSystem albo $serviceAccount."
}

$sidTypeOutput = & "$env:SystemRoot\System32\sc.exe" qsidtype $ServiceName
if ($LASTEXITCODE -ne 0 -or ($sidTypeOutput -join "`n") -notmatch 'SERVICE_SID_TYPE\s*:\s*(NONE|RESTRICTED|UNRESTRICTED)') {
    throw "Nie można odczytać typu SID usługi $ServiceName."
}
$previousSidType = $Matches[1].ToLowerInvariant()
$phpRootPaths = @($PhpRoots | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Sort-Object -Unique)
$aclTargets = @($apacheRootPath, $apacheLogsPath) + $phpRootPaths
$aclBackup = foreach ($target in $aclTargets) {
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw "Nie znaleziono katalogu wymaganego przez usługę: $target"
    }
    [pscustomobject]@{ Path = $target; Sddl = (Get-Acl -LiteralPath $target).Sddl }
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

    if ($previousSidType -ne 'unrestricted') {
        Invoke-Checked -FilePath "$env:SystemRoot\System32\sc.exe" -Arguments @('sidtype', $ServiceName, 'unrestricted')
        $serviceSidTypeChanged = $true
    }
    if ($usesLocalSystem) {
        Invoke-Checked -FilePath "$env:SystemRoot\System32\sc.exe" -Arguments @('config', $ServiceName, 'obj=', $serviceAccount)
        $serviceAccountChanged = $true
    }

    Grant-ServiceAccess -Path $apacheRootPath -Rights ReadAndExecute
    Grant-ServiceAccess -Path $apacheLogsPath -Rights Modify
    foreach ($phpRoot in $phpRootPaths) {
        Grant-ServiceAccess -Path $phpRoot -Rights ReadAndExecute
    }

    Invoke-Checked -FilePath $httpdPath -Arguments @('-t')
    if ($serviceWasRunning) {
        Start-Service -Name $ServiceName
        (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    }

    Write-Host "Usługa $ServiceName korzysta z konta $serviceAccount." -ForegroundColor Green
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
    if ($serviceSidTypeChanged) {
        & "$env:SystemRoot\System32\sc.exe" sidtype $ServiceName $previousSidType | Out-Null
    }
    Restore-Acls -Backup $aclBackup

    if ($serviceWasRunning) {
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    }

    throw
}
