Set-StrictMode -Version 2.0

$safetyRoot=Join-Path (Split-Path $PSScriptRoot -Parent) 'Safety'
Import-Module (Join-Path $PSScriptRoot 'State.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Logger.psm1') -Force
Import-Module (Join-Path $safetyRoot 'Preconditions.psm1') -Force

function New-ActionHandlerRegistry { return @{} }
function Register-ActionHandler {
    param([Parameter(Mandatory=$true)]$Registry,[Parameter(Mandatory=$true)][string]$ActionType,[Parameter(Mandatory=$true)]$Handler)
    if(-not $Handler.PSObject.Properties['Execute'] -or -not $Handler.Execute){throw "Handler '$ActionType' must expose an Execute scriptblock."}
    $Registry[$ActionType]=$Handler;return $Registry
}

function Get-DependencyOrderedActions {
    param([Parameter(Mandatory=$true)][object[]]$Actions)
    $remaining=@($Actions);$known=@{};foreach($action in $remaining){if($known.ContainsKey($action.ActionId)){throw "Duplicate action ID: $($action.ActionId)"};$known[$action.ActionId]=$true}
    foreach($action in $remaining){foreach($dependency in @($action.Dependencies)){if(-not $known.ContainsKey($dependency)){throw "Action '$($action.ActionId)' depends on unknown action '$dependency'."}}}
    $ordered=@()
    while($remaining.Count -gt 0){$ready=@($remaining | Where-Object {$deps=@($_.Dependencies);$done=$true;foreach($dep in $deps){if(-not (@($ordered | ForEach-Object {$_.ActionId}) -contains $dep)){$done=$false}};$done});if($ready.Count -eq 0){throw 'Action dependency cycle detected.'};foreach($action in $ready){$ordered+=$action;$remaining=@($remaining | Where-Object {$_.ActionId -ne $action.ActionId})}}
    return $ordered
}

function Test-ActionRequiresApproval {
    param($Action)
    if($Action.ApprovalRequired){return $true};if([string]$Action.Risk -in @('High','Medium')){return $true};if([string]$Action.ActionType -match '(?i)install|remove|delete|move|repair|create|configure|migrate|junction'){return $true};return $false
}

function Invoke-ExecutionPlan {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][object[]]$Plan,
        [Parameter(Mandatory=$true)]$HandlerRegistry,
        [Parameter(Mandatory=$true)][string]$JournalPath,
        [Parameter(Mandatory=$true)][string]$LogPath,
        [object]$Context = ([pscustomobject]@{AuditCompleted=$true}),
        [switch]$DryRun,
        [string[]]$ApprovedActionIds = @(),
        [switch]$ApproveAll
    )
    $logger=New-StructuredLogger $LogPath;$journal=Read-OperationJournal $JournalPath;$ordered=Get-DependencyOrderedActions $Plan;$interrupted=@(Get-InterruptedOperations $journal);$interruptedIds=@($interrupted | ForEach-Object {$_.ActionId});$results=@()
    if($interrupted.Count){Write-StructuredLog $logger Warning 'Interrupted operations require recovery before retry.' -Data ([pscustomobject]@{OperationIds=@($interrupted | ForEach-Object {$_.OperationId});ActionIds=$interruptedIds})}
    foreach($action in $ordered){
        $latest=@(Get-LatestOperation $journal $action.ActionId | Select-Object -First 1)
        if($interruptedIds -contains $action.ActionId){$record=Add-OperationRecord $journal $action.ActionId 'Skipped' $action.Component $action.ActionType 'Recovery required before retry.' $null 'InterruptedOperationRequiresRecovery' $null;Write-OperationJournal $journal $JournalPath;Write-StructuredLog $logger Warning 'Action skipped because a prior operation was interrupted.' $action.ActionId $action.Component; $results+=$record;continue}
        if($latest.Count -and $latest[0].Status -eq 'Completed'){$record=Add-OperationRecord $journal $action.ActionId 'Skipped' $action.Component $action.ActionType 'Already completed in a previous run.' $null 'AlreadyCompleted' $latest[0].OperationId;Write-OperationJournal $journal $JournalPath;Write-StructuredLog $logger Information 'Action skipped because it is already completed.' $action.ActionId $action.Component;$results+=$record;continue}
        $dependencyBlocked=@();foreach($dependencyId in @($action.Dependencies)){$dependencyAction=@($ordered | Where-Object {$_.ActionId -eq $dependencyId} | Select-Object -First 1);if($dependencyAction.Count -and $dependencyAction[0].CurrentStatus -in @('DISABLED','BLOCKED')){$dependencyBlocked+=$dependencyId;continue};$dependencyOperation=@(Get-LatestOperation $journal $dependencyId);if($dependencyOperation.Count -and $dependencyOperation[0].Status -notin @('Completed','Skipped')){$dependencyBlocked+=$dependencyId};if($dependencyOperation.Count -and $dependencyOperation[0].Status -eq 'Skipped' -and $dependencyOperation[0].SkipReason -notin @('NOT_REQUIRED','AlreadyCompleted')){$dependencyBlocked+=$dependencyId}}
        if($dependencyBlocked.Count){$record=Add-OperationRecord $journal $action.ActionId 'Skipped' $action.Component $action.ActionType 'A dependency did not complete successfully.' $null 'DependencyNotCompleted' $null;Write-OperationJournal $journal $JournalPath;Write-StructuredLog $logger Warning 'Action skipped because a dependency did not complete.' $action.ActionId $action.Component -Data ([pscustomobject]@{Dependencies=$dependencyBlocked});$results+=$record;continue}
        if($action.CurrentStatus -in @('NOT_REQUIRED','DISABLED','BLOCKED')){$record=Add-OperationRecord $journal $action.ActionId 'Skipped' $action.Component $action.ActionType 'Action is not executable in its current planned status.' $null ([string]$action.CurrentStatus) $null;Write-OperationJournal $journal $JournalPath;$results+=$record;continue}
        if($DryRun -or $WhatIfPreference){$reason=if($DryRun){'DryRun'}else{'WhatIf'};$record=Add-OperationRecord $journal $action.ActionId 'Skipped' $action.Component $action.ActionType 'Execution preview only; handler was not invoked.' $null $reason $null;Write-OperationJournal $journal $JournalPath;Write-StructuredLog $logger Information 'Action previewed without execution.' $action.ActionId $action.Component;$results+=$record;continue}
        $requiresApproval=Test-ActionRequiresApproval $action;if($requiresApproval -and -not $ApproveAll -and -not (@($ApprovedActionIds) -contains $action.ActionId)){$record=Add-OperationRecord $journal $action.ActionId 'Skipped' $action.Component $action.ActionType 'Explicit approval is required.' $null 'ApprovalRequired' $null;Write-OperationJournal $journal $JournalPath;Write-StructuredLog $logger Warning 'Action skipped because approval was not supplied.' $action.ActionId $action.Component;$results+=$record;continue}
        $handler=$null;if($HandlerRegistry -is [System.Collections.IDictionary] -and $HandlerRegistry.Contains($action.ActionType)){$handler=$HandlerRegistry[$action.ActionType]};if($null -eq $handler){$record=Add-OperationRecord $journal $action.ActionId 'Failed' $action.Component $action.ActionType 'No handler is registered for this action type.' 'HandlerNotFound' $null $null;Write-OperationJournal $journal $JournalPath;Write-StructuredLog $logger Error 'No handler is registered for the action type.' $action.ActionId $action.Component; $results+=$record;continue}
        $record=Add-OperationRecord $journal $action.ActionId 'Pending' $action.Component $action.ActionType 'Queued for execution.' $null $null $null;Write-OperationJournal $journal $JournalPath
        $preconditions=Test-ExecutionPreconditions $action $Context $handler;if(-not $preconditions.Passed){Update-OperationRecord $journal $record.OperationId 'Failed' 'Preconditions failed.' (($preconditions.Failures -join '; ')) 'PreconditionFailed' $null | Out-Null;Write-OperationJournal $journal $JournalPath;Write-StructuredLog $logger Error 'Action preconditions failed.' $action.ActionId $action.Component -Data $preconditions; $results+=Get-LatestOperation $journal $action.ActionId | Select-Object -First 1;continue}
        Update-OperationRecord $journal $record.OperationId 'Running' 'Handler execution started.' $null $null $null | Out-Null;Write-OperationJournal $journal $JournalPath;Write-StructuredLog $logger Information 'Handler execution started.' $action.ActionId $action.Component
        try{$handlerResult=& $handler.Execute $action $Context;Update-OperationRecord $journal $record.OperationId 'Completed' 'Handler completed.' $null $null $null | Out-Null;Write-OperationJournal $journal $JournalPath;Write-StructuredLog $logger Information 'Handler completed.' $action.ActionId $action.Component -Data $handlerResult;$results+=Get-LatestOperation $journal $action.ActionId | Select-Object -First 1}catch{$safe=Get-SanitizedError $_;Update-OperationRecord $journal $record.OperationId 'Failed' 'Handler failed.' $safe.Message 'HandlerFailed' $null | Out-Null;Write-OperationJournal $journal $JournalPath;Write-StructuredLog $logger Error 'Handler failed.' $action.ActionId $action.Component -Error $_;$results+=Get-LatestOperation $journal $action.ActionId | Select-Object -First 1}
    }
    return $results
}

Export-ModuleMember -Function New-ActionHandlerRegistry,Register-ActionHandler,Get-DependencyOrderedActions,Test-ActionRequiresApproval,Invoke-ExecutionPlan
