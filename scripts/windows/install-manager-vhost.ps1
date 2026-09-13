#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $ApacheRoot = 'C:\apache\2.4.68',

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ApacheServiceName = 'DomainManagerApache',

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $PhpCgi = 'C:\php\8.5.10\php-cgi.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$publicRoot = Join-Path $projectRoot 'public'
$dataRoot = Join-Path $projectRoot 'data'
$apacheRootPath = [IO.Path]::GetFullPath($ApacheRoot).TrimEnd('\')
$httpdPath = Join-Path $apacheRootPath 'bin\httpd.exe'
$managedDirectory = Join-Path $apacheRootPath 'conf\domain-manager'
$targetPath = Join-Path $managedDirectory 'domain-manager-self.conf'
$mkcertPath = Join-Path $env:ProgramFiles 'Domain Manager\Tools\mkcert.exe'
$caRoot = Join-Path $env:ProgramData 'DomainManager\mkcert'
$certificateDirectory = Join-Path $env:ProgramData 'DomainManager\certificates\domain-manager'
$certificatePath = Join-Path $certificateDirectory 'certificate.pem'
$privateKeyPath = Join-Path $certificateDirectory 'private-key.pem'
$previousCertificate = if (Test-Path -LiteralPath $certificatePath -PathType Leaf) { [IO.File]::ReadAllBytes($certificatePath) } else { $null }
$previousPrivateKey = if (Test-Path -LiteralPath $privateKeyPath -PathType Leaf) { [IO.File]::ReadAllBytes($privateKeyPath) } else { $null }
$certificateDirectoryExisted = Test-Path -LiteralPath $certificateDirectory -PathType Container
$certificateAclSddl = if ($certificateDirectoryExisted) { (Get-Acl -LiteralPath $certificateDirectory).Sddl } else { $null }
$serviceAccount = [Security.Principal.NTAccount]::new("NT SERVICE\$ApacheServiceName")
$serviceSid = $serviceAccount.Translate([Security.Principal.SecurityIdentifier])
$previousConfig = if (Test-Path -LiteralPath $targetPath -PathType Leaf) { [IO.File]::ReadAllBytes($targetPath) } else { $null }
$projectAclSddl = (Get-Acl -LiteralPath $projectRoot).Sddl
$dataAclSddl = (Get-Acl -LiteralPath $dataRoot).Sddl

foreach ($requiredPath in @($publicRoot, $dataRoot, $httpdPath, $PhpCgi, $mkcertPath, (Join-Path $caRoot 'rootCA-key.pem'))) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Nie znaleziono wymaganej ścieżki: $requiredPath"
    }
}
if (-not $PSCmdlet.ShouldProcess('https://domain-manager.localhost', 'Instalacja VirtualHosta HTTPS Domain Manager')) {
    return
}

function Add-ServiceRule {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [Security.AccessControl.FileSystemRights] $Rights
    )
    $acl = Get-Acl -LiteralPath $Path
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $serviceSid,
        $Rights,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Restore-Acl {
    param([string] $Path, [string] $Sddl)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetSecurityDescriptorSddlForm($Sddl)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$apachePublic = $publicRoot.Replace('\', '/')
$apachePhpCgi = ([IO.Path]::GetFullPath($PhpCgi)).Replace('\', '/')
$apachePhpRoot = ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PhpCgi))).Replace('\', '/')
$apacheCertificate = $certificatePath.Replace('\', '/')
$apachePrivateKey = $privateKeyPath.Replace('\', '/')
$configuration = @"
<VirtualHost *:80>
    ServerName domain-manager.localhost
    Redirect permanent / https://domain-manager.localhost/
</VirtualHost>

<VirtualHost *:443>
    ServerName domain-manager.localhost
    DocumentRoot "$apachePublic"
    <Directory "$apachePublic">
        Options FollowSymLinks ExecCGI
        AllowOverride None
        Require all granted
        DirectoryIndex index.php
        FallbackResource /index.php
    </Directory>
    FcgidInitialEnv PHPRC "$apachePhpRoot"
    <FilesMatch "\.php$">
        SetHandler fcgid-script
    </FilesMatch>
    FcgidWrapper "$apachePhpCgi" .php
    SSLEngine on
    SSLCertificateFile "$apacheCertificate"
    SSLCertificateKeyFile "$apachePrivateKey"
</VirtualHost>
"@

try {
    Add-ServiceRule -Path $projectRoot -Rights ReadAndExecute
    Add-ServiceRule -Path $dataRoot -Rights Modify
    New-Item -ItemType Directory -Path $managedDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $certificateDirectory -Force | Out-Null
    $previousCaroot = [Environment]::GetEnvironmentVariable('CAROOT', 'Process')
    [Environment]::SetEnvironmentVariable('CAROOT', $caRoot, 'Process')
    try {
        & $mkcertPath -cert-file $certificatePath -key-file $privateKeyPath 'domain-manager.localhost'
        if ($LASTEXITCODE -ne 0) { throw 'Nie udało się wygenerować certyfikatu Domain Managera.' }
    } finally {
        [Environment]::SetEnvironmentVariable('CAROOT', $previousCaroot, 'Process')
    }
    Add-ServiceRule -Path $certificateDirectory -Rights Read
    [IO.File]::WriteAllText($targetPath, $configuration, [Text.UTF8Encoding]::new($false))

    & $httpdPath -t
    if ($LASTEXITCODE -ne 0) { throw 'Test konfiguracji Apache nie powiódł się.' }
    & $httpdPath -k restart -n $ApacheServiceName
    if ($LASTEXITCODE -ne 0) { throw 'Nie udało się przeładować usługi Apache.' }

    $response = Invoke-WebRequest -Uri 'https://domain-manager.localhost/' -UseBasicParsing -TimeoutSec 15
    if ($response.StatusCode -ne 200 -or $response.Content -notmatch '<title>Domain Manager</title>') {
        throw 'VirtualHost nie zwrócił poprawnej strony Domain Manager.'
    }
    Write-Host 'Domain Manager działa pod adresem https://domain-manager.localhost/' -ForegroundColor Green
}
catch {
    Write-Warning 'Instalacja VirtualHosta nie powiodła się. Przywracam poprzedni stan.'
    if ($null -eq $previousConfig) {
        Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
    } else {
        [IO.File]::WriteAllBytes($targetPath, $previousConfig)
    }
    Restore-Acl -Path $projectRoot -Sddl $projectAclSddl
    Restore-Acl -Path $dataRoot -Sddl $dataAclSddl
    if ($null -eq $previousCertificate) { Remove-Item -LiteralPath $certificatePath -Force -ErrorAction SilentlyContinue } else { [IO.File]::WriteAllBytes($certificatePath, $previousCertificate) }
    if ($null -eq $previousPrivateKey) { Remove-Item -LiteralPath $privateKeyPath -Force -ErrorAction SilentlyContinue } else { [IO.File]::WriteAllBytes($privateKeyPath, $previousPrivateKey) }
    if (-not $certificateDirectoryExisted) {
        Remove-Item -LiteralPath $certificateDirectory -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($null -ne $certificateAclSddl) {
        Restore-Acl -Path $certificateDirectory -Sddl $certificateAclSddl
    }
    & $httpdPath -k restart -n $ApacheServiceName | Out-Null
    throw
}
