#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [string[]] $PhpRoots,
    [ValidatePattern('^[A-Za-z0-9._-]+$')] [string] $ApacheServiceName = 'DomainManagerApache',
    [string] $UploadTempDirectory = 'C:\php\tmp'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tempPath = [IO.Path]::GetFullPath($UploadTempDirectory).TrimEnd('\')
$iniPaths = @($PhpRoots | ForEach-Object { Join-Path ([IO.Path]::GetFullPath($_).TrimEnd('\')) 'php.ini' })
foreach ($iniPath in $iniPaths) {
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) { throw "Nie znaleziono php.ini: $iniPath" }
}
if (-not $PSCmdlet.ShouldProcess($tempPath, 'Konfiguracja bezpiecznego katalogu plików tymczasowych PHP')) { return }

$directoryExisted = Test-Path -LiteralPath $tempPath -PathType Container
$previousAcl = if ($directoryExisted) { (Get-Acl -LiteralPath $tempPath).Sddl } else { $null }
$previousIni = @{}; foreach ($iniPath in $iniPaths) { $previousIni[$iniPath] = [IO.File]::ReadAllBytes($iniPath) }
$statePath = Join-Path $env:ProgramData 'DomainManager\state\installation.json'
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 20
    if ($null -eq $state.PSObject.Properties['php_upload_tmp_directory']) {
        $state | Add-Member -NotePropertyName php_upload_tmp_directory -NotePropertyValue ([pscustomobject]@{ path = $tempPath; existed = $directoryExisted; sddl = $previousAcl })
        $temporaryState = "$statePath.$([Guid]::NewGuid().ToString('N')).tmp"
        try { $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryState -Encoding utf8NoBOM; Move-Item -LiteralPath $temporaryState -Destination $statePath -Force }
        finally { Remove-Item -LiteralPath $temporaryState -Force -ErrorAction SilentlyContinue }
    }
}

$begin = '; BEGIN Domain Manager upload temporary directory'
$end = '; END Domain Manager upload temporary directory'
$normalized = $tempPath.Replace('\', '/')
try {
    New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
    $acl = Get-Acl -LiteralPath $tempPath
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
    Set-Acl -LiteralPath $tempPath -AclObject $acl

    foreach ($iniPath in $iniPaths) {
        $contents = [IO.File]::ReadAllText($iniPath)
        $contents = [regex]::Replace($contents, "(?ms)^$([regex]::Escape($begin))\r?\n.*?^$([regex]::Escape($end))\r?\n?", '')
        $contents = $contents.TrimEnd("`r", "`n") + "`r`n`r`n$begin`r`nupload_tmp_dir = `"$normalized`"`r`n$end`r`n"
        [IO.File]::WriteAllText($iniPath, $contents, [Text.UTF8Encoding]::new($false))
    }
    Write-Host "Pliki tymczasowe uploadów PHP będą zapisywane w: $tempPath" -ForegroundColor Green
} catch {
    foreach ($iniPath in $iniPaths) { [IO.File]::WriteAllBytes($iniPath, $previousIni[$iniPath]) }
    if ($directoryExisted) { $acl = Get-Acl $tempPath; $acl.SetSecurityDescriptorSddlForm($previousAcl); Set-Acl -LiteralPath $tempPath -AclObject $acl }
    else { Remove-Item -LiteralPath $tempPath -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}
