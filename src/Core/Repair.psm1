Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Discovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Comparison.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Recovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Reporting.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'State.psm1') -Force

function Get-RepairExitCode {
    param($Execution,$Verification,$Assessments,[bool]$DryRun,[bool]$Conflict)
    if($Conflict){return 3}
    if(@($Execution | Where-Object {$_.Status -eq 'Failed'}).Count){return 1}
    if(-not $DryRun -and @($Execution | Where-Object {$_.SkipReason -eq 'ApprovalRequired'}).Count){return 2}
    if(-not $DryRun -and @($Assessments | Where-Object {$_.RecoveryClass -eq 'ManualRecoveryRequired'}).Count){return 4}
    if(-not $DryRun -and @($Verification | Where-Object {$_.Status -in @('MISMATCH','MISSING')}).Count){return 1}
    return 0
}

function Invoke-RepairWorkflow {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string]$ConfigRoot,
        [string]$ReportPath,
        [switch]$DryRun,
        [switch]$Approve,
        [string]$Component,
        [string]$OperationId,
        [hashtable]$Providers=@{},
        $Discovery,
        [string]$JournalPath,
        [string]$LogPath
    )
    $configuration=Import-AuditConfiguration $ConfigRoot;$validation=Test-BootstrapConfiguration $configuration;if(-not $validation.Passed){throw ($validation.Failures -join '; ')}
    $actual=if($null -ne $Discovery){$Discovery}else{Get-MachineDiscovery $configuration $Providers};$findings=@(Compare-AuditState $configuration $actual);$basePlan=New-BootstrapPlan $configuration $actual $findings $Component
    if([string]::IsNullOrWhiteSpace($JournalPath)){$JournalPath=Join-Path $ConfigRoot '..\logs\operations.json'};if([string]::IsNullOrWhiteSpace($LogPath)){$LogPath=Join-Path $ConfigRoot '..\logs\operations.jsonl'}
    $journal=Read-OperationJournal $JournalPath;$assessments=@(Get-RecoveryAssessment $journal $basePlan.Actions $OperationId);$recoveryActions=@(New-RecoveryPlan $assessments)
    $actions=@($basePlan.Actions | Where-Object {$_.ActionType -ne 'REVIEW_ONLY'});$actions += $recoveryActions
    $conflict=Test-BootstrapPlanConflicts $actions
    $results=@();$verification=$findings
    if($conflict.Passed) {
        $originalRegistry=New-BootstrapHandlerRegistry;$registry=New-BootstrapHandlerRegistry;$recoveryRegistry=New-RecoveryHandlerRegistry $originalRegistry;foreach($key in $recoveryRegistry.Keys){$registry[$key]=$recoveryRegistry[$key]}
        $recoveryActionMap=@{};foreach($a in @($basePlan.Actions)){$recoveryActionMap[$a.ActionId]=$a};$operationMap=@{};foreach($o in @($journal.Operations)){$operationMap[$o.OperationId]=$o}
        $context=[pscustomobject]@{AuditCompleted=$true;Configuration=$configuration;RecoveryActions=$recoveryActionMap;RecoveryOperations=$operationMap;RecoveryHandlerRegistry=$originalRegistry};foreach($key in $Providers.Keys){$context | Add-Member -NotePropertyName $key -NotePropertyValue $Providers[$key] -Force}
        if(@($actions).Count){$results=@(Invoke-ExecutionPlan $actions $registry $JournalPath $LogPath -Context $context -DryRun:$DryRun -ApproveAll:$Approve -WhatIf:$WhatIfPreference)}
        if(-not $DryRun -and $null -eq $Discovery){$verification=@(Compare-AuditState $configuration (Get-MachineDiscovery $configuration $Providers))}
    }
    $exit=Get-RepairExitCode $results $verification $assessments ([bool]$DryRun) (-not $conflict.Passed)
    if([string]::IsNullOrWhiteSpace($ReportPath)){$ReportPath=Join-Path $ConfigRoot '..\logs'}
    $report=ConvertTo-SafeReportObject $configuration $actual $findings $actions (Get-Date).ToString('o');$report | Add-Member NoteProperty Recovery ([pscustomobject]@{Assessments=@($assessments);OperationId=$OperationId}) -Force;$report | Add-Member NoteProperty Execution ([pscustomobject]@{Results=@($results);JournalPath=$JournalPath;ExitCode=$exit}) -Force;$report | Add-Member NoteProperty Verification ([pscustomobject]@{Findings=@($verification);Performed=(-not $DryRun)}) -Force;$written=Write-AuditReports $report $ReportPath
    [pscustomobject]@{ExitCode=$exit;Discovery=$actual;Findings=@($findings);Plan=@($actions);Assessments=@($assessments);Conflicts=$conflict;Execution=@($results);Verification=@($verification);Reports=$written}
}

Export-ModuleMember -Function Get-RepairExitCode,Invoke-RepairWorkflow
