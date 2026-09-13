#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $ApacheRoot = 'C:\apache\2.4.68',

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ApacheServiceName = 'DomainManagerApache',

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $CertificateDirectory = "$env:ProgramData\DomainManager\certificates\domain-manager"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serviceName = $ApacheServiceName
$httpdPath = Join-Path ([IO.Path]::GetFullPath($ApacheRoot)) 'bin\httpd.exe'
$certificateRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'DomainManager\certificates')).TrimEnd('\')
$projectCertificate = [IO.Path]::GetFullPath($CertificateDirectory)
$serviceWasRunning = (Get-Service -Name $serviceName -ErrorAction Stop).Status -eq 'Running'
$serviceSid = ([Security.Principal.NTAccount]::new("NT SERVICE\$serviceName")).Translate([Security.Principal.SecurityIdentifier])

if (-not $projectCertificate.StartsWith($certificateRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Katalog certyfikatu musi znajdować się wewnątrz $certificateRoot."
}

foreach ($path in @($httpdPath, $certificateRoot, $projectCertificate, (Join-Path $projectCertificate 'certificate.pem'), (Join-Path $projectCertificate 'private-key.pem'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Nie znaleziono wymaganego zasobu: $path" }
}
if (-not $PSCmdlet.ShouldProcess($certificateRoot, 'Nadanie usłudze Apache wyłącznie odczytu certyfikatów i ponowne uruchomienie')) { return }

$originalRootSddl = (Get-Acl -LiteralPath $certificateRoot).Sddl
$originalProjectSddl = (Get-Acl -LiteralPath $projectCertificate).Sddl

function Grant-ApacheRead {
    param([string] $Path)
    $acl = Get-Acl -LiteralPath $Path
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $serviceSid,
        [Security.AccessControl.FileSystemRights]::Read,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Restore-Sddl {
    param([string] $Path, [string] $Sddl)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetSecurityDescriptorSddlForm($Sddl)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

try {
    Grant-ApacheRead -Path $certificateRoot
    Grant-ApacheRead -Path $projectCertificate
    & $httpdPath -t
    if ($LASTEXITCODE -ne 0) { throw 'Konfiguracja Apache nadal jest nieprawidłowa.' }
    if ($serviceWasRunning) {
        & $httpdPath -k restart -n $serviceName
        if ($LASTEXITCODE -ne 0) { throw 'Nie udało się przeładować Apache.' }
    } else {
        Start-Service -Name $serviceName
        (Get-Service -Name $serviceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    }
    $response = Invoke-WebRequest -Uri 'https://domain-manager.localhost/' -UseBasicParsing -TimeoutSec 15
    if ($response.StatusCode -ne 200) { throw "Domain Manager odpowiedział kodem $($response.StatusCode)." }
    Write-Host 'Apache został przywrócony, a Domain Manager ponownie odpowiada.' -ForegroundColor Green
}
catch {
    Restore-Sddl -Path $certificateRoot -Sddl $originalRootSddl
    Restore-Sddl -Path $projectCertificate -Sddl $originalProjectSddl
    if ($serviceWasRunning) {
        & $httpdPath -k restart -n $serviceName | Out-Null
    } else {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    }
    throw
}
