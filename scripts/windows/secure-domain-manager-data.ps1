#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ApacheServiceName = 'DomainManagerApache'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'DomainManager')).TrimEnd('\')
$existed = Test-Path -LiteralPath $root -PathType Container
if (-not $existed) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
$previousSddl = (Get-Acl -LiteralPath $root).Sddl

if (-not $PSCmdlet.ShouldProcess($root, 'Ograniczenie ACL danych Domain Managera')) { return }

function New-TreeRule {
    param(
        [Parameter(Mandatory)] [Security.Principal.IdentityReference] $Identity,
        [Parameter(Mandatory)] [Security.AccessControl.FileSystemRights] $Rights
    )

    [Security.AccessControl.FileSystemAccessRule]::new(
        $Identity,
        $Rights,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
}

try {
    $acl = Get-Acl -LiteralPath $root
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }

    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $apache = ([Security.Principal.NTAccount]::new("NT SERVICE\$ApacheServiceName")).Translate([Security.Principal.SecurityIdentifier])
    $acl.AddAccessRule((New-TreeRule -Identity $system -Rights FullControl))
    $acl.AddAccessRule((New-TreeRule -Identity $administrators -Rights FullControl))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $apache,
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $root -AclObject $acl

    $effective = Get-Acl -LiteralPath $root
    $privilegedSids = @($system.Value, $administrators.Value)
    $writeMask = [Security.AccessControl.FileSystemRights]::WriteData `
        -bor [Security.AccessControl.FileSystemRights]::AppendData `
        -bor [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes `
        -bor [Security.AccessControl.FileSystemRights]::WriteAttributes `
        -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles `
        -bor [Security.AccessControl.FileSystemRights]::Delete `
        -bor [Security.AccessControl.FileSystemRights]::ChangePermissions `
        -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    $unexpectedWrite = @($effective.Access | Where-Object {
        $identitySid = $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        $_.AccessControlType -eq 'Allow' -and
        $identitySid -notin $privilegedSids -and
        ($_.FileSystemRights -band $writeMask)
    })
    if ($unexpectedWrite.Count -gt 0) {
        $details = $unexpectedWrite | ForEach-Object { "$($_.IdentityReference.Value): $($_.FileSystemRights)" }
        throw "ACL nadal zawiera niezatwierdzone prawo zapisu: $($details -join '; ')"
    }

    Write-Host "Dane Domain Managera są chronione: $root" -ForegroundColor Green
}
catch {
    $acl = Get-Acl -LiteralPath $root
    $acl.SetSecurityDescriptorSddlForm($previousSddl)
    Set-Acl -LiteralPath $root -AclObject $acl
    if (-not $existed) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}
