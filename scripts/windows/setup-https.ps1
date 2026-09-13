#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $MkcertSource = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\FiloSottile.mkcert_Microsoft.Winget.Source_8wekyb3d8bbwe\mkcert.exe",

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $ApacheRoot = 'C:\apache\2.4.68',

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ApacheServiceName = 'DomainManagerApache'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedMkcertSha256 = 'd2660b50a9ed59eada480750561c96abc2ed4c9a38c6a24d93e30e0977631398'
$programRoot = [IO.Path]::GetFullPath("$env:ProgramFiles\Domain Manager")
$toolDirectory = Join-Path $programRoot 'Tools'
$mkcertTarget = Join-Path $toolDirectory 'mkcert.exe'
$dataRoot = Join-Path $env:ProgramData 'DomainManager'
$caRoot = Join-Path $dataRoot 'mkcert'
$certificateRoot = Join-Path $dataRoot 'certificates'
$httpdPath = Join-Path ([IO.Path]::GetFullPath($ApacheRoot)) 'bin\httpd.exe'
$apacheService = Get-Service -Name $ApacheServiceName -ErrorAction Stop
$serviceWasRunning = $apacheService.Status -eq 'Running'
$managedConfigRoot = Join-Path ([IO.Path]::GetFullPath($ApacheRoot)) 'conf\domain-manager'
$baseConfig = Join-Path $managedConfigRoot '00-domain-manager-base.conf'
$previousBaseConfig = if (Test-Path -LiteralPath $baseConfig -PathType Leaf) { [IO.File]::ReadAllBytes($baseConfig) } else { $null }
$createdManagedConfigRoot = -not (Test-Path -LiteralPath $managedConfigRoot -PathType Container)
$createdCaRoot = -not (Test-Path -LiteralPath $caRoot)
$createdToolDirectory = -not (Test-Path -LiteralPath $toolDirectory)
$createdCertificateRoot = -not (Test-Path -LiteralPath $certificateRoot)
$previousMkcert = if (Test-Path -LiteralPath $mkcertTarget -PathType Leaf) { [IO.File]::ReadAllBytes($mkcertTarget) } else { $null }
$previousToolAcl = if (-not $createdToolDirectory) { (Get-Acl -LiteralPath $toolDirectory).Sddl } else { $null }
$previousCaAcl = if (-not $createdCaRoot) { (Get-Acl -LiteralPath $caRoot).Sddl } else { $null }
$previousCertificateAcl = if (-not $createdCertificateRoot) { (Get-Acl -LiteralPath $certificateRoot).Sddl } else { $null }
$newCaWasInstalled = $false

$actualHash = (Get-FileHash -LiteralPath $MkcertSource -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedMkcertSha256) {
    throw "Hash mkcert.exe jest nieprawidłowy. Oczekiwano $expectedMkcertSha256, otrzymano $actualHash."
}
if (-not $PSCmdlet.ShouldProcess($dataRoot, 'Przygotowanie lokalnego CA i HTTPS dla Domain Managera')) {
    return
}

function Set-PrivateDirectoryAcl {
    param([Parameter(Mandatory)] [string] $Path)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($acl.Access)) { [void] $acl.RemoveAccessRuleSpecific($existingRule) }
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inheritance, $propagation, $allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Restore-DirectoryAcl {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Sddl)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetSecurityDescriptorSddlForm($Sddl)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

try {
    New-Item -ItemType Directory -Path $toolDirectory, $caRoot, $certificateRoot, $managedConfigRoot -Force | Out-Null
    Copy-Item -LiteralPath $MkcertSource -Destination $mkcertTarget -Force
    Set-PrivateDirectoryAcl -Path $toolDirectory

    $previousCaroot = [Environment]::GetEnvironmentVariable('CAROOT', 'Process')
    [Environment]::SetEnvironmentVariable('CAROOT', $caRoot, 'Process')
    try {
        & $mkcertTarget -install
        if ($LASTEXITCODE -ne 0) { throw "mkcert -install zakończył się kodem $LASTEXITCODE." }
        if ($createdCaRoot) { $newCaWasInstalled = $true }
    } finally {
        [Environment]::SetEnvironmentVariable('CAROOT', $previousCaroot, 'Process')
    }

    foreach ($requiredFile in @('rootCA.pem', 'rootCA-key.pem')) {
        if (-not (Test-Path -LiteralPath (Join-Path $caRoot $requiredFile) -PathType Leaf)) {
            throw "mkcert nie utworzył pliku $requiredFile."
        }
    }
    Set-PrivateDirectoryAcl -Path $caRoot
    Set-PrivateDirectoryAcl -Path $certificateRoot

    $activeListen443 = Select-String -Path (Join-Path ([IO.Path]::GetFullPath($ApacheRoot)) 'conf\*.conf') -Pattern '^\s*Listen\s+443\s*$' -ErrorAction SilentlyContinue
    $baseContents = if ($activeListen443) { "# HTTPS port 443 is enabled outside this managed file.`r`n" } else { "Listen 443`r`n" }
    [IO.File]::WriteAllText($baseConfig, $baseContents, [Text.UTF8Encoding]::new($false))

    & $httpdPath -t
    if ($LASTEXITCODE -ne 0) { throw 'Test konfiguracji Apache nie powiódł się.' }
    if ($serviceWasRunning) {
        & $httpdPath -k restart -n $ApacheServiceName
        if ($LASTEXITCODE -ne 0) { throw 'Nie udało się przeładować Apache.' }
    }

    Write-Host 'HTTPS Domain Managera jest przygotowany.' -ForegroundColor Green
    Write-Host "CA: $caRoot"
    Write-Host "mkcert: $mkcertTarget"
}
catch {
    Write-Warning 'Konfiguracja HTTPS nie powiodła się. Przywracam poprzedni stan.'
    if ($null -eq $previousBaseConfig) { Remove-Item -LiteralPath $baseConfig -Force -ErrorAction SilentlyContinue }
    else { [IO.File]::WriteAllBytes($baseConfig, $previousBaseConfig) }
    if ($createdManagedConfigRoot) {
        Remove-Item -LiteralPath $managedConfigRoot -Force -ErrorAction SilentlyContinue
    }
    if ($newCaWasInstalled -and (Test-Path -LiteralPath $mkcertTarget -PathType Leaf)) {
        $previousCaroot = [Environment]::GetEnvironmentVariable('CAROOT', 'Process')
        [Environment]::SetEnvironmentVariable('CAROOT', $caRoot, 'Process')
        try { & $mkcertTarget -uninstall | Out-Null }
        finally { [Environment]::SetEnvironmentVariable('CAROOT', $previousCaroot, 'Process') }
    }
    if ($createdCertificateRoot) {
        Remove-Item -LiteralPath $certificateRoot -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($null -ne $previousCertificateAcl) {
        Restore-DirectoryAcl -Path $certificateRoot -Sddl $previousCertificateAcl
    }
    if ($createdCaRoot) {
        Remove-Item -LiteralPath $caRoot -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($null -ne $previousCaAcl) {
        Restore-DirectoryAcl -Path $caRoot -Sddl $previousCaAcl
    }
    if ($createdToolDirectory) {
        Remove-Item -LiteralPath $toolDirectory -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        if ($null -eq $previousMkcert) {
            Remove-Item -LiteralPath $mkcertTarget -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::WriteAllBytes($mkcertTarget, $previousMkcert)
        }
        if ($null -ne $previousToolAcl) { Restore-DirectoryAcl -Path $toolDirectory -Sddl $previousToolAcl }
    }
    if ($serviceWasRunning) {
        & $httpdPath -k restart -n $ApacheServiceName | Out-Null
    }
    throw
}
