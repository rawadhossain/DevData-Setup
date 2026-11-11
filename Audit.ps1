[CmdletBinding()]
param([string]$ConfigRoot = (Join-Path $PSScriptRoot 'config'))

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if(-not (Test-Path -LiteralPath $ConfigRoot)){ throw "Configuration root not found: $ConfigRoot" }
$core = Join-Path $PSScriptRoot 'src\Core'
Import-Module (Join-Path $core 'Configuration.psm1') -Force
Import-Module (Join-Path $core 'Discovery.psm1') -Force
Import-Module (Join-Path $core 'Comparison.psm1') -Force
Import-Module (Join-Path $core 'Planner.psm1') -Force
Import-Module (Join-Path $core 'Reporting.psm1') -Force

$configuration = Import-AuditConfiguration $ConfigRoot
$discovery = Get-MachineDiscovery $configuration
$findings = Compare-AuditState $configuration $discovery
$disabledComponents=@()
if(-not $configuration.junctions.enabled){$disabledComponents += 'Junction'}
foreach($app in $configuration.applications.applications){if(-not $app.enabled){$disabledComponents += ('Application ' + $app.id)}}
$plan = New-PlanFromFindings $findings $disabledComponents
$report = ConvertTo-SafeReportObject $configuration $discovery $findings $plan (Get-Date).ToString('o')
$written = Write-AuditReports $report (Join-Path $PSScriptRoot 'logs')

Write-Output ("JSON report: {0}" -f $written.JsonPath)
Write-Output ("Markdown report: {0}" -f $written.MarkdownPath)
Write-Output ("Findings: {0}" -f @($findings).Count)
