[CmdletBinding(SupportsShouldProcess)]
param([string]$ConfigRoot = (Join-Path $PSScriptRoot 'config'), [switch]$DryRun)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Write-Warning 'Uninstall functionality is not implemented in Task 001. No changes were made.'
exit 0
