#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $RuntimeConfiguration = (Join-Path $PSScriptRoot '..\..\config\runtime.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serviceName = 'DomainManagerHelper'
$installPath = [IO.Path]::GetFullPath("$env:ProgramFiles\Domain Manager\Helper").TrimEnd('\')
$projectPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\helper\windows\DomainManager.Helper.csproj'))
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$stagingPath = Join-Path $env:ProgramData "DomainManager\staging\helper-update-$runId"
$backupPath = Join-Path $env:ProgramData "DomainManager\backups\helper-$runId"
$service = Get-Service -Name $serviceName -ErrorAction Stop
$serviceWasRunning = $service.Status -eq 'Running'
$runtimeConfigPath = Join-Path $env:ProgramData 'DomainManager\config\runtime.json'
$runtimeConfigDirectory = Split-Path -Parent $runtimeConfigPath
$runtimeConfigDirectoryExisted = Test-Path -LiteralPath $runtimeConfigDirectory -PathType Container
$previousRuntimeConfig = if (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf) { [IO.File]::ReadAllBytes($runtimeConfigPath) } else { $null }
$previousRuntimeConfigAcl = if ($runtimeConfigDirectoryExisted) { (Get-Acl -LiteralPath $runtimeConfigDirectory).Sddl } else { $null }

if (-not (Test-Path -LiteralPath (Join-Path $installPath 'domain-manager-helper.exe') -PathType Leaf)) {
    throw "Nie znaleziono istniejącej instalacji helpera w $installPath."
}
if (-not $PSCmdlet.ShouldProcess($installPath, "Aktualizacja usługi $serviceName z rollbackiem")) {
    return
}

function Copy-DirectoryContents {
    param([string] $Source, [string] $Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

function Restore-RuntimeConfiguration {
    if ($null -eq $previousRuntimeConfig) {
        Remove-Item -LiteralPath $runtimeConfigPath -Force -ErrorAction SilentlyContinue
    } else {
        [IO.File]::WriteAllBytes($runtimeConfigPath, $previousRuntimeConfig)
    }
    if (-not $runtimeConfigDirectoryExisted) {
        Remove-Item -LiteralPath $runtimeConfigDirectory -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($null -ne $previousRuntimeConfigAcl) {
        $acl = Get-Acl -LiteralPath $runtimeConfigDirectory
        $acl.SetSecurityDescriptorSddlForm($previousRuntimeConfigAcl)
        Set-Acl -LiteralPath $runtimeConfigDirectory -AclObject $acl
    }
}

try {
    & (Join-Path $PSScriptRoot 'install-runtime-configuration.ps1') -SourcePath $RuntimeConfiguration -Confirm:$false
    New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
    & dotnet publish $projectPath -c Release -o $stagingPath
    if ($LASTEXITCODE -ne 0) { throw 'Publikacja helpera nie powiodła się.' }
    if (-not (Test-Path -LiteralPath (Join-Path $stagingPath 'domain-manager-helper.exe') -PathType Leaf)) {
        throw 'Publikacja nie utworzyła pliku wykonywalnego helpera.'
    }

    Copy-DirectoryContents -Source $installPath -Destination $backupPath
    if ($serviceWasRunning) {
        Stop-Service -Name $serviceName -Force
        (Get-Service -Name $serviceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    }

    Get-ChildItem -LiteralPath $installPath -Force | Remove-Item -Recurse -Force
    Copy-DirectoryContents -Source $stagingPath -Destination $installPath
    Start-Service -Name $serviceName
    (Get-Service -Name $serviceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))

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
            throw 'Test zaktualizowanej usługi nie powiódł się.'
        }
    } finally {
        $pipe.Dispose()
    }

    if (-not $serviceWasRunning) {
        Stop-Service -Name $serviceName -Force
        (Get-Service -Name $serviceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    }

    Write-Host "Helper został zaktualizowany. Backup: $backupPath" -ForegroundColor Green
}
catch {
    Write-Warning 'Aktualizacja nie powiodła się. Przywracam poprzednią wersję helpera.'
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $backupPath -PathType Container) {
        Get-ChildItem -LiteralPath $installPath -Force | Remove-Item -Recurse -Force
        Copy-DirectoryContents -Source $backupPath -Destination $installPath
    }
    Restore-RuntimeConfiguration
    if ($serviceWasRunning) {
        Start-Service -Name $serviceName -ErrorAction SilentlyContinue
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stagingPath -PathType Container) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
}
