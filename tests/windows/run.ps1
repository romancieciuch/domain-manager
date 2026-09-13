[CmdletBinding()]
param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scripts = @(
    (Join-Path $repositoryRoot 'install.ps1'),
    (Join-Path $repositoryRoot 'uninstall.ps1')
) + @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'scripts\windows') -Filter '*.ps1' | Select-Object -ExpandProperty FullName) +
    @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tests\windows') -Filter '*.ps1' | Select-Object -ExpandProperty FullName)
$scripts = @($scripts | Sort-Object -Unique)

$syntaxErrors = @()
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    foreach ($parseError in $errors) {
        $syntaxErrors += "${script}:$($parseError.Extent.StartLineNumber): $($parseError.Message)"
    }
}
if ($syntaxErrors.Count -gt 0) {
    throw "Błędy składni PowerShell:`n$($syntaxErrors -join "`n")"
}
Write-Host "OK: składnia $($scripts.Count) skryptów PowerShell"

& php (Join-Path $repositoryRoot 'tests\run.php')
if ($LASTEXITCODE -ne 0) {
    throw "Testy PHP zakończyły się kodem $LASTEXITCODE."
}

if (-not $SkipBuild) {
    $helperProject = Join-Path $repositoryRoot 'helper\windows\DomainManager.Helper.csproj'
    & dotnet build $helperProject --nologo
    if ($LASTEXITCODE -ne 0) {
        throw "Build helpera zakończył się kodem $LASTEXITCODE."
    }

    & dotnet run --no-build --project $helperProject -- --self-test-redaction
    if ($LASTEXITCODE -ne 0) {
        throw 'Test redakcji sekretów helpera nie powiódł się.'
    }
    Write-Host 'OK: redakcja sekretów helpera'
}

Write-Host 'OK: zestaw testów Windows zakończony powodzeniem.'
