#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [string[]] $PhpRoots,
    [string[]] $Extensions = @('curl', 'fileinfo', 'gd', 'mbstring', 'mysqli', 'openssl', 'pdo_mysql', 'pdo_pgsql', 'pdo_sqlite', 'pgsql', 'soap', 'sockets', 'sqlite3', 'zip')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$begin = '; BEGIN Domain Manager PHP extensions'
$end = '; END Domain Manager PHP extensions'

foreach ($root in $PhpRoots) {
    $phpRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $iniPath = Join-Path $phpRoot 'php.ini'
    $phpPath = Join-Path $phpRoot 'php.exe'
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) { throw "Nie znaleziono php.ini: $iniPath" }
    if (-not (Test-Path -LiteralPath $phpPath -PathType Leaf)) { throw "Nie znaleziono php.exe: $phpPath" }
    foreach ($extension in $Extensions) {
        if ($extension -notmatch '^[a-z0-9_]+$') { throw "Nieprawidłowa nazwa rozszerzenia: $extension" }
        $dll = Join-Path $phpRoot "ext\php_$extension.dll"
        if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { throw "Brakuje biblioteki rozszerzenia PHP: $dll" }
    }
    if (-not $PSCmdlet.ShouldProcess($iniPath, "Włączenie rozszerzeń PHP: $($Extensions -join ', ')")) { continue }

    $previous = [IO.File]::ReadAllBytes($iniPath)
    try {
        $contents = [IO.File]::ReadAllText($iniPath)
        $contents = [regex]::Replace($contents, "(?ms)^$([regex]::Escape($begin))\r?\n.*?^$([regex]::Escape($end))\r?\n?", '')
        $names = ($Extensions | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $contents = [regex]::Replace($contents, "(?im)^\s*extension\s*=\s*`"?(?:php_)?(?:$names)(?:\.dll)?`"?\s*(?:;.*)?\r?\n", '')
        $managed = ($Extensions | ForEach-Object { "extension=$_" }) -join "`r`n"
        $contents = $contents.TrimEnd("`r", "`n") + "`r`n`r`n$begin`r`n$managed`r`n$end`r`n"
        [IO.File]::WriteAllText($iniPath, $contents, [Text.UTF8Encoding]::new($false))

        $modules = @(& $phpPath -m 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "PHP nie uruchamia się poprawnie po zmianie: $phpPath" }
        foreach ($extension in $Extensions) {
            if ($modules -notcontains $extension) { throw "Rozszerzenie $extension nie zostało załadowane przez $phpPath" }
        }
        Write-Host "Skonfigurowano rozszerzenia PHP: $phpRoot" -ForegroundColor Green
    } catch {
        [IO.File]::WriteAllBytes($iniPath, $previous)
        throw
    }
}
