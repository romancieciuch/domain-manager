#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(1, 100)] [int] $MaximumFiles = 5,
    [ValidateRange(1, 1024)] [int] $MaximumFileSizeMb = 10,
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })] [string] $ApacheRoot = 'C:\apache\2.4.68',
    [ValidatePattern('^[A-Za-z0-9._-]+$')] [string] $ServiceName = 'DomainManagerApache'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$httpdPath = Join-Path $apacheRoot 'bin\httpd.exe'
$rotatelogsPath = Join-Path $apacheRoot 'bin\rotatelogs.exe'
$baseConfig = Join-Path $apacheRoot 'conf\domain-manager\00-domain-manager-base.conf'
$serviceWasRunning = (Get-Service -Name $serviceName -ErrorAction Stop).Status -eq 'Running'

foreach ($path in @($httpdPath, $rotatelogsPath, $baseConfig)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Nie znaleziono wymaganego pliku: $path" }
}
if (-not $PSCmdlet.ShouldProcess($baseConfig, "Rotacja error_log: $MaximumFiles plików po ${MaximumFileSizeMb} MB")) { return }

$previousConfig = [IO.File]::ReadAllBytes($baseConfig)
$contents = [IO.File]::ReadAllText($baseConfig)
$apachePath = ([IO.Path]::GetFullPath($ApacheRoot)).Replace('\', '/')
$directive = "ErrorLog `"|$apachePath/bin/rotatelogs.exe -f -n $MaximumFiles $apachePath/logs/error_log ${MaximumFileSizeMb}M`""
$contents = [regex]::Replace($contents, '(?m)^\s*ErrorLog\s+"\|.*rotatelogs\.exe.*$\r?\n?', '')
$contents = $contents.TrimEnd("`r", "`n") + "`r`n$directive`r`n"

try {
    [IO.File]::WriteAllText($baseConfig, $contents, [Text.UTF8Encoding]::new($false))
    & $httpdPath -t
    if ($LASTEXITCODE -ne 0) { throw 'Test konfiguracji Apache nie powiódł się.' }
    if ($serviceWasRunning) {
        & $httpdPath -k restart -n $serviceName
        if ($LASTEXITCODE -ne 0) { throw 'Nie udało się przeładować Apache.' }
        Start-Sleep -Seconds 2
        if ((Get-Service $serviceName).Status -ne 'Running') { throw 'Apache zatrzymał się po zmianie konfiguracji logów.' }
        $response = Invoke-WebRequest -Uri 'http://domain-manager.localhost/' -UseBasicParsing -TimeoutSec 15
        if ($response.StatusCode -ne 200 -or $response.Content -notmatch '<title>Domain Manager</title>') {
            throw 'Domain Manager nie odpowiedział poprawnie po restarcie.'
        }
    }
    Write-Host "Rotacja error_log działa: maksymalnie $MaximumFiles plików po ${MaximumFileSizeMb} MB." -ForegroundColor Green
}
catch {
    [IO.File]::WriteAllBytes($baseConfig, $previousConfig)
    if ($serviceWasRunning) { & $httpdPath -k restart -n $serviceName | Out-Null }
    throw
}
