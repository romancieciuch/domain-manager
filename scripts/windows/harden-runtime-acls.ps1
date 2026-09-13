#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ServiceName = 'DomainManagerApache',

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $ApacheRoot = 'C:\apache\2.4.68',

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $PhpRoot = 'C:\php\8.5.10'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$apacheRootPath = [IO.Path]::GetFullPath($ApacheRoot).TrimEnd('\')
$phpRootPath = [IO.Path]::GetFullPath($PhpRoot).TrimEnd('\')
$apacheLogsPath = Join-Path $apacheRootPath 'logs'
$httpdPath = Join-Path $apacheRootPath 'bin\httpd.exe'
$serviceAccountName = "NT SERVICE\$ServiceName"
$backupDirectory = Join-Path $env:ProgramData 'DomainManager\backups'
$backupPath = Join-Path $backupDirectory ("runtime-acls-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$serviceWasRunning = (Get-Service -Name $ServiceName -ErrorAction Stop).Status -eq 'Running'

foreach ($requiredPath in @($apacheRootPath, $phpRootPath, $apacheLogsPath, $httpdPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Nie znaleziono wymaganej ścieżki: $requiredPath"
    }
}

$targets = @($apacheRootPath, $phpRootPath, $apacheLogsPath)
$backup = foreach ($target in $targets) {
    $acl = Get-Acl -LiteralPath $target
    [pscustomobject]@{
        Path = $target
        Sddl = $acl.Sddl
    }
}

function New-InheritedRule {
    param(
        [Parameter(Mandatory)] [System.Security.Principal.IdentityReference] $Identity,
        [Parameter(Mandatory)] [System.Security.AccessControl.FileSystemRights] $Rights
    )

    return [System.Security.AccessControl.FileSystemAccessRule]::new(
        $Identity,
        $Rights,
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
}

function Set-RuntimeRootAcl {
    param([Parameter(Mandatory)] [string] $Path)

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($rule in @($acl.Access)) {
        [void] $acl.RemoveAccessRuleSpecific($rule)
    }

    $administrators = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $users = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $service = ([System.Security.Principal.NTAccount]::new($serviceAccountName)).Translate([System.Security.Principal.SecurityIdentifier])

    $acl.AddAccessRule((New-InheritedRule -Identity $administrators -Rights FullControl))
    $acl.AddAccessRule((New-InheritedRule -Identity $system -Rights FullControl))
    $acl.AddAccessRule((New-InheritedRule -Identity $users -Rights ReadAndExecute))
    $acl.AddAccessRule((New-InheritedRule -Identity $service -Rights ReadAndExecute))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Grant-LogWriteAccess {
    $acl = Get-Acl -LiteralPath $apacheLogsPath
    $service = ([System.Security.Principal.NTAccount]::new($serviceAccountName)).Translate([System.Security.Principal.SecurityIdentifier])
    $acl.AddAccessRule((New-InheritedRule -Identity $service -Rights Modify))
    Set-Acl -LiteralPath $apacheLogsPath -AclObject $acl
}

function Restore-OriginalAcls {
    foreach ($entry in $backup) {
        $acl = Get-Acl -LiteralPath $entry.Path
        $acl.SetSecurityDescriptorSddlForm($entry.Sddl)
        Set-Acl -LiteralPath $entry.Path -AclObject $acl
    }
}

if (-not $PSCmdlet.ShouldProcess("$apacheRootPath oraz $phpRootPath", 'Utwardzenie uprawnień ACL runtime')) {
    return
}

New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
$backup | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $backupPath -Encoding utf8NoBOM

try {
    if ($serviceWasRunning) {
        Stop-Service -Name $ServiceName -Force
        (Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    }

    Set-RuntimeRootAcl -Path $apacheRootPath
    Set-RuntimeRootAcl -Path $phpRootPath
    Grant-LogWriteAccess

    & $httpdPath -t
    if ($LASTEXITCODE -ne 0) {
        throw "Test konfiguracji Apache zakończył się kodem $LASTEXITCODE."
    }

    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))

    $response = Invoke-WebRequest -Uri 'http://localhost/' -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -ne 200) {
        throw "Apache odpowiedział kodem HTTP $($response.StatusCode)."
    }

    Write-Host 'Uprawnienia runtime zostały utwardzone.' -ForegroundColor Green
    Write-Host "Backup ACL: $backupPath"
}
catch {
    Write-Warning 'Test po zmianie ACL nie powiódł się. Przywracam poprzednie deskryptory.'
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Restore-OriginalAcls

    if ($serviceWasRunning) {
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    }

    throw
}

