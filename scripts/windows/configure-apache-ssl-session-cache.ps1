#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })] [string] $ApacheRoot = 'C:\apache\2.4.68',
    [ValidatePattern('^[A-Za-z0-9._-]+$')] [string] $ServiceName = 'DomainManagerApache'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($ApacheRoot).TrimEnd('\')
$httpd = Join-Path $root 'bin\httpd.exe'
$httpdConfig = Join-Path $root 'conf\httpd.conf'
$module = Join-Path $root 'modules\mod_socache_shmcb.so'
$managedRoot = Join-Path $root 'conf\domain-manager'
$cacheConfig = Join-Path $managedRoot '00-ssl-session-cache.conf'
foreach ($path in @($httpd, $httpdConfig, $module)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Nie znaleziono: $path" } }
$service = Get-Service -Name $ServiceName -ErrorAction Stop
$wasRunning = $service.Status -eq 'Running'
if (-not $PSCmdlet.ShouldProcess($httpdConfig, 'Włączenie pamięci podręcznej sesji TLS Apache')) { return }

$previousHttpd = [IO.File]::ReadAllBytes($httpdConfig)
$previousCache = if (Test-Path -LiteralPath $cacheConfig -PathType Leaf) { [IO.File]::ReadAllBytes($cacheConfig) } else { $null }
try {
    $contents = [IO.File]::ReadAllText($httpdConfig)
    if ($contents -notmatch '(?im)^\s*LoadModule\s+socache_shmcb_module\s+modules/mod_socache_shmcb\.so\s*$') {
        $next = [regex]::Replace($contents, '(?im)^\s*#\s*LoadModule\s+socache_shmcb_module\s+modules/mod_socache_shmcb\.so\s*$', 'LoadModule socache_shmcb_module modules/mod_socache_shmcb.so', 1)
        if ($next -eq $contents) { throw 'Nie znaleziono dyrektywy LoadModule socache_shmcb_module w httpd.conf.' }
        [IO.File]::WriteAllText($httpdConfig, $next, [Text.UTF8Encoding]::new($false))
    }

    New-Item -ItemType Directory -Path $managedRoot -Force | Out-Null
    $cacheContents = @'
<IfModule ssl_module>
    SSLSessionCache "shmcb:${SRVROOT}/logs/ssl_scache(512000)"
    SSLSessionCacheTimeout 300
</IfModule>
'@
    [IO.File]::WriteAllText($cacheConfig, $cacheContents.Trim() + "`r`n", [Text.UTF8Encoding]::new($false))
    & $httpd -t
    if ($LASTEXITCODE -ne 0) { throw 'Test konfiguracji Apache nie powiódł się po włączeniu SSLSessionCache.' }
    if ($wasRunning) {
        & $httpd -k restart -n $ServiceName
        if ($LASTEXITCODE -ne 0) { throw 'Nie udało się przeładować Apache.' }
    }
    Write-Host 'Pamięć podręczna sesji TLS Apache jest aktywna.' -ForegroundColor Green
} catch {
    [IO.File]::WriteAllBytes($httpdConfig, $previousHttpd)
    if ($null -eq $previousCache) { Remove-Item -LiteralPath $cacheConfig -Force -ErrorAction SilentlyContinue }
    else { [IO.File]::WriteAllBytes($cacheConfig, $previousCache) }
    if ($wasRunning) { & $httpd -k restart -n $ServiceName | Out-Null }
    throw
}
