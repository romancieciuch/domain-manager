#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [string[]] $PhpRoots,
    [ValidatePattern('^[A-Za-z0-9._-]+$')] [string] $ApacheServiceName = 'DomainManagerApache',
    [string] $SessionDirectory = 'C:\temp\php-sessions'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sessionPath = [IO.Path]::GetFullPath($SessionDirectory).TrimEnd('\')
$iniPaths = @($PhpRoots | ForEach-Object { Join-Path ([IO.Path]::GetFullPath($_).TrimEnd('\')) 'php.ini' })
foreach ($iniPath in $iniPaths) {
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) { throw "Nie znaleziono php.ini: $iniPath" }
}
if (-not $PSCmdlet.ShouldProcess($sessionPath, 'Konfiguracja bezpiecznego katalogu sesji PHP')) { return }

$directoryExisted = Test-Path -LiteralPath $sessionPath -PathType Container
$previousAcl = if ($directoryExisted) { (Get-Acl -LiteralPath $sessionPath).Sddl } else { $null }
$previousIni = @{}; foreach ($iniPath in $iniPaths) { $previousIni[$iniPath] = [IO.File]::ReadAllBytes($iniPath) }
$statePath = Join-Path $env:ProgramData 'DomainManager\state\installation.json'
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 20
    if ($null -eq $state.PSObject.Properties['php_ini_files']) {
        $state | Add-Member -NotePropertyName php_ini_files -NotePropertyValue @($iniPaths | ForEach-Object { [pscustomobject]@{ path = $_; base64 = [Convert]::ToBase64String($previousIni[$_]) } })
        $state | Add-Member -NotePropertyName php_session_directory -NotePropertyValue ([pscustomobject]@{ path = $sessionPath; existed = $directoryExisted; sddl = $previousAcl })
        $temporaryState = "$statePath.$([Guid]::NewGuid().ToString('N')).tmp"
        try { $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryState -Encoding utf8NoBOM; Move-Item -LiteralPath $temporaryState -Destination $statePath -Force }
        finally { Remove-Item -LiteralPath $temporaryState -Force -ErrorAction SilentlyContinue }
    }
}
$begin = '; BEGIN Domain Manager session configuration'
$end = '; END Domain Manager session configuration'
$normalized = $sessionPath.Replace('\', '/')

try {
    New-Item -ItemType Directory -Path $sessionPath -Force | Out-Null
    $acl = Get-Acl -LiteralPath $sessionPath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $identities = @(
        @([Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.AccessControl.FileSystemRights]::FullControl),
        @([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'), [Security.AccessControl.FileSystemRights]::FullControl),
        @(([Security.Principal.NTAccount]::new("NT SERVICE\$ApacheServiceName")).Translate([Security.Principal.SecurityIdentifier]), [Security.AccessControl.FileSystemRights]::Modify)
    )
    foreach ($entry in $identities) { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($entry[0], $entry[1], $inheritance, $propagation, $allow)) }
    Set-Acl -LiteralPath $sessionPath -AclObject $acl

    foreach ($iniPath in $iniPaths) {
        $contents = [IO.File]::ReadAllText($iniPath)
        $contents = [regex]::Replace($contents, "(?ms)^$([regex]::Escape($begin))\r?\n.*?^$([regex]::Escape($end))\r?\n?", '')
        $contents = $contents.TrimEnd("`r", "`n") + "`r`n`r`n$begin`r`nsession.save_path = `"$normalized`"`r`n$end`r`n"
        [IO.File]::WriteAllText($iniPath, $contents, [Text.UTF8Encoding]::new($false))
    }
    Write-Host "Sesje PHP będą zapisywane w: $sessionPath" -ForegroundColor Green
} catch {
    foreach ($iniPath in $iniPaths) { [IO.File]::WriteAllBytes($iniPath, $previousIni[$iniPath]) }
    if ($directoryExisted) { $acl = Get-Acl $sessionPath; $acl.SetSecurityDescriptorSddlForm($previousAcl); Set-Acl $sessionPath $acl }
    else { Remove-Item -LiteralPath $sessionPath -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}
