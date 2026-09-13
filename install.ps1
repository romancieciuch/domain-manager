#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string] $RuntimeConfiguration = (Join-Path $PSScriptRoot 'config\runtime.json'),
    [string] $MkcertSource = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string] $Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Stop-WithGuidance([string[]] $Problems) {
    Write-Host "`nInstalacja nie może jeszcze wystartować:" -ForegroundColor Yellow
    foreach ($problem in $Problems) { Write-Host "  - $problem" -ForegroundColor Yellow }
    throw 'Uzupełnij wymagania opisane powyżej i uruchom install.ps1 ponownie.'
}

$runtimePath = [IO.Path]::GetFullPath($RuntimeConfiguration)
if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) { Stop-WithGuidance @("Brakuje pliku $runtimePath.") }
$runtime = Get-Content -Raw -LiteralPath $runtimePath | ConvertFrom-Json -Depth 20
$apacheRoot = [IO.Path]::GetFullPath([string] $runtime.apache.root)
$apacheService = [string] $runtime.apache.service_name
$httpd = Join-Path $apacheRoot 'bin\httpd.exe'
$phpEntries = @($runtime.php.versions.PSObject.Properties)
$defaultPhp = [string] $runtime.php.default_version
$defaultEntry = $phpEntries | Where-Object Name -eq $defaultPhp | Select-Object -First 1
$problems = [Collections.Generic.List[string]]::new()

Write-Host 'Domain Manager — instalator Windows' -ForegroundColor Blue
Write-Host "Konfiguracja: $runtimePath"

if ($runtime.schema_version -ne 1 -or $runtime.platform -ne 'windows') { $problems.Add('runtime.json musi mieć schema_version 1 i platformę windows.') }
if ($null -eq $defaultEntry) { $problems.Add("Domyślna wersja PHP $defaultPhp nie istnieje w php.versions.") }
if (-not (Test-Path -LiteralPath $httpd -PathType Leaf)) { $problems.Add("Nie znaleziono Apache: $httpd") }
if ($phpEntries.Count -eq 0) { $problems.Add('Dodaj co najmniej jedną wersję PHP w config/runtime.json.') }

foreach ($entry in $phpEntries) {
    foreach ($property in @('cli', 'cgi')) {
        $binary = [IO.Path]::GetFullPath([string] $entry.Value.$property)
        if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { $problems.Add("PHP $($entry.Name): brakuje $binary") }
    }
}
foreach ($root in @($runtime.projects.allowed_roots)) {
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetFullPath([string] $root)) -PathType Container)) {
        $problems.Add("Dozwolony katalog projektów nie istnieje: $root")
    }
}
if ($problems.Count -gt 0) { Stop-WithGuidance $problems }

Write-Step 'Sprawdzam rozszerzenia PHP'
foreach ($entry in $phpEntries) {
    $cli = [IO.Path]::GetFullPath([string] $entry.Value.cli)
    $modules = @(& $cli -m 2>$null)
    foreach ($module in @('PDO', 'pdo_sqlite', 'sqlite3')) {
        if ($modules -notcontains $module) {
            $problems.Add("PHP $($entry.Name): w php.ini włącz rozszerzenie $module (usuń średnik przed extension=$module).")
        }
    }
}

Write-Step 'Sprawdzam moduły Apache'
$moduleOutput = @(& $httpd -M 2>&1)
$moduleText = $moduleOutput -join "`n"
if ($LASTEXITCODE -ne 0) { $problems.Add("Apache nie potrafi odczytać konfiguracji: $($moduleOutput -join ' ')") }
foreach ($module in @('rewrite_module', 'ssl_module', 'fcgid_module')) {
    if ($moduleText -notmatch "\b$([regex]::Escape($module))\b") {
        $problems.Add("Apache: włącz $module w conf/httpd.conf.")
    }
}
if ($problems.Count -gt 0) { Stop-WithGuidance $problems }
Write-Host 'Wymagania PHP i Apache są spełnione.' -ForegroundColor Green

if (-not (Get-Service -Name $apacheService -ErrorAction SilentlyContinue)) {
    Write-Step "Instaluję usługę Apache $apacheService"
    & $httpd -k install -n $apacheService
    if ($LASTEXITCODE -ne 0) { throw 'Nie udało się zainstalować usługi Apache.' }
}

$phpRoots = @($phpEntries | ForEach-Object { [IO.Path]::GetFullPath([string] $_.Value.root) })
$defaultPhpRoot = [IO.Path]::GetFullPath([string] $defaultEntry.Value.root)
$defaultPhpCli = [IO.Path]::GetFullPath([string] $defaultEntry.Value.cli)
$defaultPhpCgi = [IO.Path]::GetFullPath([string] $defaultEntry.Value.cgi)

Write-Step 'Zabezpieczam usługę i katalogi runtime'
& "$PSScriptRoot\scripts\windows\secure-apache-service.ps1" -ServiceName $apacheService -ApacheRoot $apacheRoot -PhpRoots $phpRoots -Confirm:$false
& "$PSScriptRoot\scripts\windows\harden-runtime-acls.ps1" -ServiceName $apacheService -ApacheRoot $apacheRoot -PhpRoot $defaultPhpRoot -Confirm:$false

$caKey = Join-Path $env:ProgramData 'DomainManager\mkcert\rootCA-key.pem'
if (-not (Test-Path -LiteralPath $caKey -PathType Leaf)) {
    if ($MkcertSource -eq '') {
        $mkcertCommand = Get-Command mkcert.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $mkcertCommand) { $MkcertSource = $mkcertCommand.Source }
    }
    if ($MkcertSource -eq '' -or -not (Test-Path -LiteralPath $MkcertSource -PathType Leaf)) {
        Stop-WithGuidance @('Nie znaleziono mkcert. Zainstaluj zweryfikowany pakiet poleceniem: winget install FiloSottile.mkcert, a potem uruchom instalator ponownie.')
    }
    Write-Step 'Przygotowuję lokalne, zaufane HTTPS'
    & "$PSScriptRoot\scripts\windows\setup-https.ps1" -MkcertSource $MkcertSource -ApacheRoot $apacheRoot -ApacheServiceName $apacheService -Confirm:$false
}

Write-Step 'Tworzę bazę SQLite i uruchamiam migracje'
& $defaultPhpCli "$PSScriptRoot\bin\migrate.php"
if ($LASTEXITCODE -ne 0) { throw 'Migracje SQLite nie powiodły się.' }

Write-Step 'Instaluję stronę Domain Managera'
& "$PSScriptRoot\scripts\windows\install-manager-vhost.ps1" -ApacheRoot $apacheRoot -ApacheServiceName $apacheService -PhpCgi $defaultPhpCgi -Confirm:$false

Write-Step 'Instaluję lub aktualizuję ograniczony helper'
if (Get-Service -Name DomainManagerHelper -ErrorAction SilentlyContinue) {
    & "$PSScriptRoot\scripts\windows\update-helper-service.ps1" -Confirm:$false
} else {
    & "$PSScriptRoot\scripts\windows\install-helper-service.ps1" -ApacheServiceName $apacheService -Confirm:$false
}

Write-Step 'Włączam rotację logów i autostart'
& "$PSScriptRoot\scripts\windows\configure-apache-log-rotation.ps1" -ApacheRoot $apacheRoot -ServiceName $apacheService -Confirm:$false
& "$PSScriptRoot\scripts\windows\enable-domain-manager-autostart.ps1" -ApacheRoot $apacheRoot -ApacheServiceName $apacheService -Confirm:$false

Write-Step 'Test końcowy'
& $httpd -t
if ($LASTEXITCODE -ne 0) { throw 'Końcowy test Apache nie powiódł się.' }
$response = Invoke-WebRequest -Uri 'https://domain-manager.localhost/' -UseBasicParsing -TimeoutSec 15
if ($response.StatusCode -ne 200 -or $response.Content -notmatch '<title>Domain Manager</title>') {
    throw 'Domain Manager nie odpowiedział prawidłowo po instalacji.'
}
Write-Host "`nDomain Manager jest gotowy: https://domain-manager.localhost/" -ForegroundColor Green
