#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $RuntimeConfiguration = (Join-Path $PSScriptRoot '..\..\config\runtime.json'),
    [ValidateSet(2, 3, 4)] [int] $OriginalIisStart = 2,
    [bool] $OriginalIisRunning = $true,
    [switch] $ApacheWasPreExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runtimePath = [IO.Path]::GetFullPath($RuntimeConfiguration)
$runtime = Get-Content -Raw -LiteralPath $runtimePath | ConvertFrom-Json -Depth 20
if ($runtime.schema_version -ne 1 -or $runtime.platform -ne 'windows') { throw 'Nieprawidłowy runtime.json.' }

$apacheRoot = [IO.Path]::GetFullPath([string]$runtime.apache.root).TrimEnd('\')
$apacheServiceName = [string]$runtime.apache.service_name
if ($apacheServiceName -notmatch '^[A-Za-z0-9._-]+$') { throw 'Nieprawidłowa nazwa usługi Apache.' }
$httpdConfig = Join-Path $apacheRoot 'conf\httpd.conf'
$stateRoot = Join-Path $env:ProgramData 'DomainManager\state'
$statePath = Join-Path $stateRoot 'installation.json'
$backupRoot = Join-Path $env:ProgramData 'DomainManager\backups'

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    throw "Migawka już istnieje i nie zostanie nadpisana: $statePath"
}
$httpdBackup = Get-ChildItem -LiteralPath (Split-Path -Parent $httpdConfig) -Filter 'httpd.conf.domain-manager-*.backup' -File |
    Sort-Object LastWriteTimeUtc | Select-Object -First 1
$aclBackup = Get-ChildItem -LiteralPath $backupRoot -Filter 'runtime-acls-*.json' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc | Select-Object -First 1
if ($null -eq $httpdBackup) { throw 'Nie znaleziono historycznego backupu httpd.conf.' }
if ($null -eq $aclBackup) { throw 'Nie znaleziono historycznego backupu ACL runtime.' }
if ($ApacheWasPreExisting) {
    throw 'Migracja nie potrafi wiarygodnie odtworzyć pierwotnego konta i SID istniejącej wcześniej usługi Apache. Użyj nowej instalacji albo przygotuj migawkę ręcznie.'
}
$aclEntries = @(Get-Content -Raw -LiteralPath $aclBackup.FullName | ConvertFrom-Json)
foreach ($entry in $aclEntries) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Path) -or [string]::IsNullOrWhiteSpace([string]$entry.Sddl)) {
        throw "Nieprawidłowy wpis w backupie ACL: $($aclBackup.FullName)"
    }
}
$iisExists = $null -ne (Get-Service -Name W3SVC -ErrorAction SilentlyContinue)
$state = [pscustomobject]@{
    schema_version = 1
    created_at = (Get-Date).ToUniversalTime().ToString('o')
    migrated_from_legacy_installation = $true
    apache_service_name = $apacheServiceName
    apache_service = [pscustomobject]@{ exists = $false }
    iis_service = [pscustomobject]@{
        exists = $iisExists
        running = $OriginalIisRunning
        start = $OriginalIisStart
        delayed = $false
        account = $null
        sid_type = $null
    }
    httpd_config_path = $httpdConfig
    httpd_config_base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($httpdBackup.FullName))
    runtime_acls = @($aclEntries | ForEach-Object { [pscustomobject]@{ path = [string]$_.Path; sddl = [string]$_.Sddl } })
}

Write-Host "Źródło httpd.conf: $($httpdBackup.FullName)"
Write-Host "Źródło ACL: $($aclBackup.FullName)"
Write-Host "Założenie IIS: start=$OriginalIisStart, running=$OriginalIisRunning"
Write-Host 'Założenie Apache: usługa została utworzona przez Domain Manager.'
if (-not $PSCmdlet.ShouldProcess($statePath, 'Utworzenie migawki dla starszej instalacji')) { return }

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$acl = Get-Acl -LiteralPath $stateRoot
$acl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
$inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$propagation = [Security.AccessControl.PropagationFlags]::None
$allow = [Security.AccessControl.AccessControlType]::Allow
foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {
    $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inheritance, $propagation, $allow))
}
Set-Acl -LiteralPath $stateRoot -AclObject $acl
$temporary = "$statePath.$([Guid]::NewGuid().ToString('N')).tmp"
try {
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $statePath
} finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}
Write-Host "Migracja migawki zakończona: $statePath" -ForegroundColor Green
