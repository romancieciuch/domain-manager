#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $SourcePath = (Join-Path $PSScriptRoot '..\..\config\runtime.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = [IO.Path]::GetFullPath($SourcePath)
$targetDirectory = Join-Path $env:ProgramData 'DomainManager\config'
$target = Join-Path $targetDirectory 'runtime.json'
$targetDirectoryExisted = Test-Path -LiteralPath $targetDirectory -PathType Container
$previousTarget = if (Test-Path -LiteralPath $target -PathType Leaf) { [IO.File]::ReadAllBytes($target) } else { $null }
$previousDirectoryAcl = if ($targetDirectoryExisted) { (Get-Acl -LiteralPath $targetDirectory).Sddl } else { $null }

if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Nie znaleziono konfiguracji: $source" }
$runtime = Get-Content -Raw -LiteralPath $source | ConvertFrom-Json -Depth 20
if ($runtime.schema_version -ne 1 -or $runtime.platform -ne 'windows') { throw 'Nieobsługiwana wersja lub platforma konfiguracji.' }
if ($runtime.apache.service_name -notmatch '^[A-Za-z0-9._-]+$') { throw 'Nieprawidłowa nazwa usługi Apache.' }

$apacheRoot = [IO.Path]::GetFullPath([string] $runtime.apache.root)
foreach ($required in @((Join-Path $apacheRoot 'bin\httpd.exe'), (Join-Path $apacheRoot 'conf\httpd.conf'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Brakuje wymaganego pliku: $required" }
}

$allowedRoots = @($runtime.projects.allowed_roots)
if ($allowedRoots.Count -ne 1) { throw 'Windows MVP wymaga dokładnie jednego dozwolonego katalogu projektów.' }
$allowedRoot = [IO.Path]::GetFullPath([string] $allowedRoots[0])
if (-not (Test-Path -LiteralPath $allowedRoot -PathType Container)) { throw "Katalog projektów nie istnieje: $allowedRoot" }

$phpVersions = @($runtime.php.versions.PSObject.Properties)
if ($phpVersions.Count -eq 0) { throw 'Nie skonfigurowano żadnej wersji PHP.' }
foreach ($version in $phpVersions) {
    if ($version.Name -notmatch '^\d+\.\d+\.\d+$') { throw "Nieprawidłowy numer wersji PHP: $($version.Name)" }
    $cgi = [IO.Path]::GetFullPath([string] $version.Value.cgi)
    if ([IO.Path]::GetFileName($cgi) -ne 'php-cgi.exe' -or -not (Test-Path -LiteralPath $cgi -PathType Leaf)) {
        throw "PHP $($version.Name) nie zawiera prawidłowego php-cgi.exe: $cgi"
    }
}

if (-not $PSCmdlet.ShouldProcess($target, 'Instalacja chronionej konfiguracji środowiska')) { return }
$temporary = "$target.$([Guid]::NewGuid().ToString('N')).tmp"
try {
    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $temporary
    Move-Item -LiteralPath $temporary -Destination $target -Force

    $acl = Get-Acl -LiteralPath $targetDirectory
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void] $acl.RemoveAccessRuleSpecific($rule) }
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inheritance, $propagation, $allow)
        [void] $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $targetDirectory -AclObject $acl
    Write-Host "Chroniona konfiguracja została zainstalowana: $target" -ForegroundColor Green
}
catch {
    if ($null -eq $previousTarget) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    } else {
        [IO.File]::WriteAllBytes($target, $previousTarget)
    }
    if (-not $targetDirectoryExisted) {
        Remove-Item -LiteralPath $targetDirectory -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($null -ne $previousDirectoryAcl) {
        $acl = Get-Acl -LiteralPath $targetDirectory
        $acl.SetSecurityDescriptorSddlForm($previousDirectoryAcl)
        Set-Acl -LiteralPath $targetDirectory -AclObject $acl
    }
    throw
}
finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}
