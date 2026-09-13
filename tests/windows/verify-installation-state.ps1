#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$path = Join-Path $env:ProgramData 'DomainManager\state\installation.json'
$state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 20
if ($state.schema_version -ne 1) { throw 'Nieprawidłowa wersja schematu migawki.' }
if (-not $state.migrated_from_legacy_installation) { throw 'Migawka nie została oznaczona jako migracja starszej instalacji.' }
if ([bool]$state.apache_service.exists) { throw 'Starsza instalacja miała zostać oznaczona jako utworzona przez Domain Manager.' }
if (-not [bool]$state.iis_service.exists) { throw 'Migawka nie zawiera usługi IIS.' }
if (@($state.runtime_acls).Count -eq 0) { throw 'Migawka nie zawiera ACL-i runtime.' }
if ([string]::IsNullOrWhiteSpace([string]$state.httpd_config_base64)) { throw 'Migawka nie zawiera httpd.conf.' }
[void][Convert]::FromBase64String([string]$state.httpd_config_base64)
Write-Host "OK: chroniona migawka instalacji jest kompletna ($(@($state.runtime_acls).Count) ACL)." -ForegroundColor Green
