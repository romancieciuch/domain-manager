#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ServiceName = 'DomainManagerHelper',

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ApacheServiceName = 'DomainManagerApache',

    [ValidateNotNullOrEmpty()]
    [string] $InstallDirectory = "$env:ProgramFiles\Domain Manager\Helper"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\helper\windows\DomainManager.Helper.csproj'))
$installPath = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$programFilesPath = [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
$stagingPath = Join-Path $env:ProgramData ("DomainManager\staging\helper-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$executablePath = Join-Path $installPath 'domain-manager-helper.exe'
$serviceBinaryPath = '"{0}" --service' -f $executablePath
$serviceExisted = $null -ne (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
$installDirectoryExisted = Test-Path -LiteralPath $installPath

if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw "Nie znaleziono projektu helpera: $projectPath"
}
if ($serviceExisted) {
    throw "Usługa $ServiceName już istnieje. Przerwano bez zmian."
}
if (-not $installPath.StartsWith($programFilesPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Katalog instalacji musi być podkatalogiem $programFilesPath."
}
if ($installDirectoryExisted -and (Get-ChildItem -LiteralPath $installPath -Force | Select-Object -First 1)) {
    throw "Katalog instalacji nie jest pusty: $installPath. Przerwano bez zmian."
}
if (-not (Get-Service -Name $ApacheServiceName -ErrorAction SilentlyContinue)) {
    throw "Nie znaleziono usługi Apache $ApacheServiceName wymaganej przez ACL Named Pipe."
}
if (-not $PSCmdlet.ShouldProcess($installPath, "Publikacja i rejestracja usługi $ServiceName")) {
    return
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Polecenie zakończyło się kodem ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

try {
    & (Join-Path $PSScriptRoot 'install-runtime-configuration.ps1') -Confirm:$false
    New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
    Invoke-Checked -FilePath 'dotnet' -Arguments @('publish', $projectPath, '-c', 'Release', '--no-restore', '-o', $stagingPath)
    if (-not (Test-Path -LiteralPath (Join-Path $stagingPath 'domain-manager-helper.exe') -PathType Leaf)) {
        throw 'Publikacja nie utworzyła pliku wykonywalnego helpera.'
    }

    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    Get-ChildItem -LiteralPath $stagingPath -Force | Copy-Item -Destination $installPath -Recurse -Force

    $acl = Get-Acl -LiteralPath $installPath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($acl.Access)) {
        [void] $acl.RemoveAccessRuleSpecific($existingRule)
    }
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
        $accessRule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inheritance, $propagation, $allow)
        $acl.AddAccessRule($accessRule)
    }
    Set-Acl -LiteralPath $installPath -AclObject $acl

    Invoke-Checked -FilePath "$env:SystemRoot\System32\sc.exe" -Arguments @('create', $ServiceName, 'binPath=', $serviceBinaryPath, 'start=', 'auto', 'obj=', 'LocalSystem', 'DisplayName=', 'Domain Manager privileged helper')
    Invoke-Checked -FilePath "$env:SystemRoot\System32\sc.exe" -Arguments @('description', $ServiceName, 'Ograniczony helper operacji systemowych Domain Manager.')
    Invoke-Checked -FilePath "$env:SystemRoot\System32\sc.exe" -Arguments @('sidtype', $ServiceName, 'unrestricted')
    Invoke-Checked -FilePath "$env:SystemRoot\System32\sc.exe" -Arguments @('failure', $ServiceName, 'reset=', '86400', 'actions=', 'restart/5000/restart/15000/none/0')

    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))

    $requestId = [Guid]::NewGuid().ToString()
    $request = @{ protocol = 1; request_id = $requestId; action = 'helper.status'; arguments = @{} } | ConvertTo-Json -Compress
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'DomainManager.Helper.v1', [IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    try {
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 4096, $true)
        $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 4096, $true)
        $writer.WriteLine($request)
        $writer.Flush()
        $response = $reader.ReadLine() | ConvertFrom-Json
        if (-not $response.ok -or $response.request_id -ne $requestId -or -not $response.data.elevated) {
            throw 'Helper odpowiedział nieprawidłowo na test statusu.'
        }
    }
    finally {
        $pipe.Dispose()
    }

    Write-Host "Usługa $ServiceName działa, a test Named Pipe zakończył się powodzeniem." -ForegroundColor Green
    Write-Host "Katalog instalacji: $installPath"
}
catch {
    Write-Warning 'Instalacja helpera nie powiodła się. Wycofuję utworzone elementy.'
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    if (-not $serviceExisted -and (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        & "$env:SystemRoot\System32\sc.exe" delete $ServiceName | Out-Null
    }
    if (-not $serviceExisted -and -not $installDirectoryExisted -and (Test-Path -LiteralPath $installPath)) {
        Remove-Item -LiteralPath $installPath -Recurse -Force
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
}
