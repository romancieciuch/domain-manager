#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ApacheRoot,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9._-]+$')] [string] $ApacheServiceName,
    [Parameter(Mandatory)] [string[]] $PhpRoots
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:ProgramData 'DomainManager\state'
$statePath = Join-Path $stateRoot 'installation.json'
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    Write-Host "Zachowuję istniejącą migawkę stanu sprzed pierwszej instalacji: $statePath"
    return
}

function Get-ServiceState([string] $Name) {
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) { return [pscustomobject]@{ exists = $false } }
    $key = Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$Name"
    $delayed = $key.PSObject.Properties['DelayedAutostart']
    $qc = (& "$env:SystemRoot\System32\sc.exe" qc $Name) -join "`n"
    $sid = (& "$env:SystemRoot\System32\sc.exe" qsidtype $Name) -join "`n"
    [pscustomobject]@{
        exists = $true
        running = $service.Status -eq 'Running'
        start = [int]$key.Start
        delayed = $null -ne $delayed -and $delayed.Value -eq 1
        account = if ($qc -match 'SERVICE_START_NAME\s*:\s*(.+)') { $Matches[1].Trim() } else { $null }
        sid_type = if ($sid -match 'SERVICE_SID_TYPE\s*:\s*(NONE|RESTRICTED|UNRESTRICTED)') { $Matches[1].ToLowerInvariant() } else { $null }
    }
}

$apacheRootPath = [IO.Path]::GetFullPath($ApacheRoot).TrimEnd('\')
$httpdConfig = Join-Path $apacheRootPath 'conf\httpd.conf'
$aclPaths = @($apacheRootPath, (Join-Path $apacheRootPath 'logs')) + @($PhpRoots | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
$acls = foreach ($path in $aclPaths | Sort-Object -Unique) {
    if (Test-Path -LiteralPath $path -PathType Container) {
        [pscustomobject]@{ path = $path; sddl = (Get-Acl -LiteralPath $path).Sddl }
    }
}
$state = [pscustomobject]@{
    schema_version = 1
    created_at = (Get-Date).ToUniversalTime().ToString('o')
    apache_service_name = $ApacheServiceName
    apache_service = Get-ServiceState $ApacheServiceName
    iis_service = Get-ServiceState 'W3SVC'
    httpd_config_path = $httpdConfig
    httpd_config_base64 = if (Test-Path -LiteralPath $httpdConfig -PathType Leaf) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($httpdConfig)) } else { $null }
    runtime_acls = @($acls)
}

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$stateAcl = Get-Acl -LiteralPath $stateRoot
$stateAcl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($stateAcl.Access)) { [void]$stateAcl.RemoveAccessRuleSpecific($rule) }
$inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$propagation = [Security.AccessControl.PropagationFlags]::None
$allow = [Security.AccessControl.AccessControlType]::Allow
foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {
    $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
    $stateAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inheritance, $propagation, $allow))
}
Set-Acl -LiteralPath $stateRoot -AclObject $stateAcl
$temporary = "$statePath.$([Guid]::NewGuid().ToString('N')).tmp"
try {
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $statePath -Force
    Write-Host "Zapisano stan sprzed instalacji: $statePath" -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}
