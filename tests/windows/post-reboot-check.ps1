#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'DomainManagerPostRebootCheck'
$resultDirectory = Join-Path $env:ProgramData 'DomainManager\logs'
$resultPath = Join-Path $resultDirectory 'post-reboot-result.json'
$result = [ordered]@{
    checked_at = (Get-Date).ToUniversalTime().ToString('o')
    boot_time = $null
    success = $false
    apache = $null
    helper = $null
    iis = $null
    helper_pipe = $false
    https_status = $null
    https_title_ok = $false
    error = $null
}

try {
    $result.boot_time = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    $deadline = (Get-Date).AddMinutes(5)
    do {
        $apache = Get-Service DomainManagerApache -ErrorAction Stop
        $helper = Get-Service DomainManagerHelper -ErrorAction Stop
        if ($apache.Status -eq 'Running' -and $helper.Status -eq 'Running') { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    $iis = Get-Service W3SVC -ErrorAction SilentlyContinue
    $result.apache = @{ status = [string]$apache.Status; start_type = [string]$apache.StartType }
    $result.helper = @{ status = [string]$helper.Status; start_type = [string]$helper.StartType }
    $result.iis = if ($null -eq $iis) { @{ exists = $false } } else {
        @{ exists = $true; status = [string]$iis.Status; start_type = [string]$iis.StartType }
    }
    if ($apache.Status -ne 'Running' -or $helper.Status -ne 'Running') { throw 'Usługi nie uruchomiły się w ciągu 5 minut.' }

    $requestId = [Guid]::NewGuid().ToString()
    $request = @{ protocol = 1; request_id = $requestId; action = 'helper.status'; arguments = @{} } | ConvertTo-Json -Compress
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'DomainManager.Helper.v1', [IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    try {
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 4096, $true)
        $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 4096, $true)
        $writer.WriteLine($request)
        $writer.Flush()
        $pipeResponse = $reader.ReadLine() | ConvertFrom-Json
        $result.helper_pipe = [bool]($pipeResponse.ok -and $pipeResponse.request_id -eq $requestId -and $pipeResponse.data.elevated)
    } finally {
        $pipe.Dispose()
    }
    if (-not $result.helper_pipe) { throw 'Helper nie odpowiedział prawidłowo przez Named Pipe.' }

    $response = Invoke-WebRequest -Uri 'https://domain-manager.localhost/' -UseBasicParsing -TimeoutSec 15
    $result.https_status = $response.StatusCode
    $result.https_title_ok = $response.Content -match '<title>Domain Manager</title>'
    if ($response.StatusCode -ne 200 -or -not $result.https_title_ok) { throw 'HTTPS nie zwrócił strony Domain Managera.' }
    $result.success = $true
}
catch {
    $result.error = $_.Exception.Message
}
finally {
    New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
    $temporary = "$resultPath.$([Guid]::NewGuid().ToString('N')).tmp"
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $resultPath -Force
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

if (-not $result.success) { exit 1 }
