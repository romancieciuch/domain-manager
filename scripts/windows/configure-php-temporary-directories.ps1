#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [string[]] $PhpRoots,
    [ValidatePattern('^[A-Za-z0-9._-]+$')] [string] $ApacheServiceName = 'DomainManagerApache',
    [string] $TemporaryDirectory = 'C:\php\tmp'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$temporaryPath = [IO.Path]::GetFullPath($TemporaryDirectory).TrimEnd('\')
$iniPaths = @($PhpRoots | ForEach-Object { Join-Path ([IO.Path]::GetFullPath($_).TrimEnd('\')) 'php.ini' })
foreach ($iniPath in $iniPaths) {
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) { throw "Nie znaleziono php.ini: $iniPath" }
}
if (-not $PSCmdlet.ShouldProcess($temporaryPath, 'Konfiguracja wspólnych katalogów tymczasowych PHP')) { return }

$directoryExisted = Test-Path -LiteralPath $temporaryPath -PathType Container
$previousAcl = if ($directoryExisted) { (Get-Acl -LiteralPath $temporaryPath).Sddl } else { $null }
$previousIni = @{}; foreach ($iniPath in $iniPaths) { $previousIni[$iniPath] = [IO.File]::ReadAllBytes($iniPath) }
$statePath = Join-Path $env:ProgramData 'DomainManager\state\installation.json'
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 20
    $stateChanged = $false
    if ($null -eq $state.PSObject.Properties['php_ini_files']) {
        $state | Add-Member -NotePropertyName php_ini_files -NotePropertyValue @($iniPaths | ForEach-Object { [pscustomobject]@{ path = $_; base64 = [Convert]::ToBase64String($previousIni[$_]) } })
        $stateChanged = $true
    }
    if ($null -eq $state.PSObject.Properties['php_session_directory']) {
        $oldSessionDirectory = 'C:\temp\php-sessions'
        $oldSessionExisted = Test-Path -LiteralPath $oldSessionDirectory -PathType Container
        $oldSessionSddl = if ($oldSessionExisted) { (Get-Acl -LiteralPath $oldSessionDirectory).Sddl } else { $null }
        $state | Add-Member -NotePropertyName php_session_directory -NotePropertyValue ([pscustomobject]@{ path = $oldSessionDirectory; existed = $oldSessionExisted; sddl = $oldSessionSddl })
        $stateChanged = $true
    }
    if ($null -eq $state.PSObject.Properties['php_upload_tmp_directory']) {
        $state | Add-Member -NotePropertyName php_upload_tmp_directory -NotePropertyValue ([pscustomobject]@{ path = $temporaryPath; existed = $directoryExisted; sddl = $previousAcl })
        $stateChanged = $true
    }
    if ($stateChanged) {
        $temporaryState = "$statePath.$([Guid]::NewGuid().ToString('N')).tmp"
        try { $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryState -Encoding utf8NoBOM; Move-Item -LiteralPath $temporaryState -Destination $statePath -Force }
        finally { Remove-Item -LiteralPath $temporaryState -Force -ErrorAction SilentlyContinue }
    }
}

$begin = '; BEGIN Domain Manager PHP temporary directories'
$end = '; END Domain Manager PHP temporary directories'
$normalized = $temporaryPath.Replace('\', '/')
try {
    New-Item -ItemType Directory -Path $temporaryPath -Force | Out-Null
    $acl = Get-Acl -LiteralPath $temporaryPath
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
    Set-Acl -LiteralPath $temporaryPath -AclObject $acl

    foreach ($iniPath in $iniPaths) {
        $contents = [IO.File]::ReadAllText($iniPath)
        foreach ($oldBlock in @(
            @('; BEGIN Domain Manager session configuration', '; END Domain Manager session configuration'),
            @('; BEGIN Domain Manager upload temporary directory', '; END Domain Manager upload temporary directory')
        )) {
            $contents = [regex]::Replace($contents, "(?ms)^$([regex]::Escape($oldBlock[0]))\r?\n.*?^$([regex]::Escape($oldBlock[1]))\r?\n?", '')
        }
        $contents = [regex]::Replace($contents, '(?im)^\s*(?:session\.save_path|upload_tmp_dir|sys_temp_dir)\s*=.*\r?\n', '')
        $managed = @(
            $begin,
            "session.save_path = `"$normalized`"",
            "upload_tmp_dir = `"$normalized`"",
            "sys_temp_dir = `"$normalized`"",
            $end
        ) -join "`r`n"
        $contents = $contents.TrimEnd("`r", "`n") + "`r`n`r`n$managed`r`n"
        [IO.File]::WriteAllText($iniPath, $contents, [Text.UTF8Encoding]::new($false))
    }
    Write-Host "Sesje, uploady i pliki tymczasowe PHP będą używać: $temporaryPath" -ForegroundColor Green
} catch {
    foreach ($iniPath in $iniPaths) { [IO.File]::WriteAllBytes($iniPath, $previousIni[$iniPath]) }
    if ($directoryExisted) { $acl = Get-Acl $temporaryPath; $acl.SetSecurityDescriptorSddlForm($previousAcl); Set-Acl -LiteralPath $temporaryPath -AclObject $acl }
    else { Remove-Item -LiteralPath $temporaryPath -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}
