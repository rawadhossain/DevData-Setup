[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config'),
    [string]$ReportPath = (Join-Path $PSScriptRoot 'logs'),
    [string]$Component,
    [switch]$DryRun,
    [switch]$Approve
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot 'src\Core\Bootstrap.psm1'
Import-Module $module -Force
$result = Invoke-BootstrapWorkflow -ConfigRoot $ConfigPath -ReportPath $ReportPath -Component $Component -DryRun:$DryRun -Approve:$Approve -WhatIf:$WhatIfPreference
Write-Output ('Bootstrap exit code: {0}' -f $result.ExitCode)
Write-Output ('Actions: {0}; completed: {1}; failed: {2}; skipped: {3}' -f @($result.Plan).Count, @($result.Execution | Where-Object Status -eq 'Completed').Count, @($result.Execution | Where-Object Status -eq 'Failed').Count, @($result.Execution | Where-Object Status -eq 'Skipped').Count)
Write-Output ('JSON report: {0}' -f $result.Reports.JsonPath)
Write-Output ('Markdown report: {0}' -f $result.Reports.MarkdownPath)
$global:LASTEXITCODE = $result.ExitCode
exit $result.ExitCode
