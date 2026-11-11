[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$ConfigRoot = (Join-Path $PSScriptRoot 'config'),
    [switch]$DryRun,
    [string]$JournalPath = (Join-Path $PSScriptRoot 'logs\installation-journal.json'),
    [string]$LogPath = (Join-Path $PSScriptRoot 'logs\installation-operations.jsonl'),
    [string[]]$ApprovedActionIds = @(),
    [switch]$ApproveAll
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if(-not (Test-Path -LiteralPath $ConfigRoot -PathType Container)){throw "Configuration root not found: $ConfigRoot"}
$core=Join-Path $PSScriptRoot 'src\Core';$install=Join-Path $PSScriptRoot 'src\Install'
Import-Module (Join-Path $core 'Configuration.psm1') -Force
Import-Module (Join-Path $core 'Discovery.psm1') -Force
Import-Module (Join-Path $install 'Installation.psm1')

$configuration=Import-AuditConfiguration $ConfigRoot
$discovery=Get-MachineDiscovery $configuration
$plan=@(Get-InstallationPlan $configuration $discovery)
if(-not $plan.Count){Write-Output 'No managed installation actions are configured.';return}
$registry=New-InstallationHandlerRegistry
$context=[pscustomobject]@{AuditCompleted=$true;Configuration=$configuration;Discovery=$discovery}
$results=@(Invoke-ExecutionPlan -Plan $plan -HandlerRegistry $registry -JournalPath $JournalPath -LogPath $LogPath -Context $context -DryRun:$DryRun -ApprovedActionIds $ApprovedActionIds -ApproveAll:$ApproveAll)
Write-Output ("Planned actions: {0}" -f $plan.Count)
Write-Output ("Completed: {0}" -f @($results | Where-Object {$_.Status -eq 'Completed'}).Count)
Write-Output ("Skipped: {0}" -f @($results | Where-Object {$_.Status -eq 'Skipped'}).Count)
Write-Output ("Failed: {0}" -f @($results | Where-Object {$_.Status -eq 'Failed'}).Count)
