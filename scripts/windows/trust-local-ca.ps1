#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param([string] $CertificatePath = "$env:ProgramData\DomainManager\mkcert\rootCA.pem")

$ErrorActionPreference = 'Stop'
$path = [IO.Path]::GetFullPath($CertificatePath)
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Brakuje lokalnego CA: $path" }
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($path)
$thumbprint = $certificate.Thumbprint
$existing = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -EQ $thumbprint
if ($null -eq $existing -and $PSCmdlet.ShouldProcess("LocalMachine\Root\$thumbprint", 'Dodanie lokalnego CA Domain Managera')) {
    & "$env:SystemRoot\System32\certutil.exe" -addstore -f Root $path | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Nie udało się dodać lokalnego CA do magazynu systemowego.' }
}
if ($null -eq (Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -EQ $thumbprint)) {
    throw 'Lokalne CA nie jest obecne w magazynie LocalMachine\Root.'
}
Write-Host "Lokalne CA jest zaufane systemowo: $thumbprint" -ForegroundColor Green
