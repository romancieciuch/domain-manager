#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string] $RuntimeConfiguration = (Join-Path $PSScriptRoot '..\..\config\runtime.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runtime = Get-Content -Raw -LiteralPath ([IO.Path]::GetFullPath($RuntimeConfiguration)) | ConvertFrom-Json -Depth 20
$apacheServiceName = [string]$runtime.apache.service_name
$httpd = Join-Path ([IO.Path]::GetFullPath([string]$runtime.apache.root)) 'bin\httpd.exe'
$serviceNames = @('DomainManagerHelper', $apacheServiceName)
$initiallyRunning = @{}

foreach ($name in $serviceNames) {
    $service = Get-Service -Name $name -ErrorAction Stop
    $initiallyRunning[$name] = $service.Status -eq 'Running'
    if ($service.StartType -notin @('Automatic', 'AutomaticDelayedStart')) {
        throw "Usługa $name nie ma automatycznego trybu startu: $($service.StartType)."
    }
}

function Wait-ServiceState([string] $Name, [string] $State) {
    (Get-Service -Name $Name).WaitForStatus($State, [TimeSpan]::FromSeconds(20))
}

try {
    foreach ($name in @($apacheServiceName, 'DomainManagerHelper')) {
        Stop-Service -Name $name -Force
        Wait-ServiceState -Name $name -State 'Stopped'
    }

    Start-Service -Name 'DomainManagerHelper'
    Wait-ServiceState -Name 'DomainManagerHelper' -State 'Running'
    Start-Service -Name $apacheServiceName
    Wait-ServiceState -Name $apacheServiceName -State 'Running'

    & $httpd -t
    if ($LASTEXITCODE -ne 0) { throw 'Test konfiguracji Apache nie powiódł się po restarcie.' }

    $requestId = [Guid]::NewGuid().ToString()
    $request = @{ protocol = 1; request_id = $requestId; action = 'helper.status'; arguments = @{} } | ConvertTo-Json -Compress
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'DomainManager.Helper.v1', [IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    try {
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 4096, $true)
        $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 4096, $true)
        $writer.WriteLine($request)
        $writer.Flush()
        $helperResponse = $reader.ReadLine() | ConvertFrom-Json
        if (-not $helperResponse.ok -or $helperResponse.request_id -ne $requestId -or -not $helperResponse.data.elevated) {
            throw 'Helper odpowiedział nieprawidłowo po restarcie.'
        }
    } finally {
        $pipe.Dispose()
    }

    $response = Invoke-WebRequest -Uri 'https://domain-manager.localhost/' -UseBasicParsing -TimeoutSec 15
    if ($response.StatusCode -ne 200 -or $response.Content -notmatch '<title>Domain Manager</title>') {
        throw 'HTTPS Domain Managera nie działa po restarcie usług.'
    }
    Write-Host 'OK: Apache, helper, Named Pipe i HTTPS działają po kontrolowanym restarcie.' -ForegroundColor Green
}
catch {
    foreach ($name in $serviceNames) {
        if ($initiallyRunning[$name] -and (Get-Service $name).Status -ne 'Running') {
            Start-Service $name -ErrorAction SilentlyContinue
        }
    }
    throw
}
