Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'State.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Planner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Executor.psm1') -Force
Import-Module (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Safety') 'Rollback.psm1') -Force

function Get-RecoveryClass {
    param($Operation,$Action)
    if($Operation.Status -eq 'Running') {
        return [pscustomobject]@{Class='ManualRecoveryRequired';SafeToAutomate=$false;Reason='Operation was interrupted while running; mutation boundary is unknown.';RecommendedAction='Inspect the affected paths and operation-specific recovery metadata manually before any retry or rollback.'}
    }
    if($null -eq $Action) {
        return [pscustomobject]@{Class='ManualRecoveryRequired';SafeToAutomate=$false;Reason='Original planned action is not available.';RecommendedAction='Locate the original plan and inspect affected paths manually.'}
    }
    if($Operation.Status -eq 'Completed' -and $Action.ActionType -eq 'JUNCTION_CREATE') {
        return [pscustomobject]@{Class='Reversible';SafeToAutomate=$false;Reason='Completed junction creation has a target-validating rollback handler.';RecommendedAction='Approve targeted rollback only after validating the junction target and ownership.'}
    }
    if($Action.ActionType -match 'MIGRATE|INSTALL|ENVIRONMENT|PATH|APPLICATION|DOCKER|WSL') {
        return [pscustomobject]@{Class='ManualRecoveryRequired';SafeToAutomate=$false;Reason='Handler exposes recovery guidance, but not enough persisted state for autonomous rollback.';RecommendedAction='Follow the operation recovery instructions; preserve originals, backups, and unknown data.'}
    }
    return [pscustomobject]@{Class='ManualRecoveryRequired';SafeToAutomate=$false;Reason='No safe generic rollback contract is available for this action.';RecommendedAction='Review the operation record and affected paths manually.'}
}

function Get-RecoveryAssessment {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Journal,[object[]]$Actions=@(),[string]$OperationId)
    $records=@($Journal.Operations | Where-Object {$_.Status -in @('Pending','Running','Failed') -or ($OperationId -and $_.OperationId -eq $OperationId)})
    if($OperationId -and -not @($records).Count) { throw "Operation not found in journal: $OperationId" }
    $result=@()
    foreach($record in $records) {
        $action=@($Actions | Where-Object {$_.ActionId -eq $record.ActionId} | Select-Object -First 1)
        $matchedAction=$null
        if($action.Count){$matchedAction=$action[0]}
        $classification=Get-RecoveryClass $record $matchedAction
        $result += [pscustomobject][ordered]@{
            OperationId=$record.OperationId;ActionId=$record.ActionId;Component=$record.Component;ActionType=$record.ActionType;OriginalStatus=$record.Status
            AffectedPaths=if($action.Count){@($action[0].AffectedPaths)}else{@()};RecoveryClass=$classification.Class;SafeToAutomate=$classification.SafeToAutomate
            Reason=$classification.Reason;RecommendedAction=$classification.RecommendedAction;RequiresApproval=$true
        }
    }
    return @($result)
}

function New-RecoveryBlockedAction {
    param($Assessment)
    $action=New-PlannedAction -ActionId ('RECOVERY-REVIEW-'+$Assessment.OperationId) -Component ('Recovery '+$Assessment.Component) -Description $Assessment.RecommendedAction -ActionType 'RECOVERY_REVIEW' -Risk 'High' -AffectedPaths @($Assessment.AffectedPaths) -Preconditions @('Manual recovery review is complete.') -ApprovalRequired $false -SafeToAutomate $false -CurrentStatus 'BLOCKED' -RollbackInformation 'No recovery mutation was performed.'
    Add-Member -InputObject $action -MemberType NoteProperty -Name RecoveryMetadata -Value $Assessment
    return $action
}

function New-RecoveryRollbackAction {
    param($Assessment)
    $action=New-PlannedAction -ActionId ('RECOVERY-'+$Assessment.OperationId) -Component ('Recovery '+$Assessment.Component) -Description $Assessment.RecommendedAction -ActionType 'RECOVERY_ROLLBACK' -Risk 'High' -AffectedPaths @($Assessment.AffectedPaths) -Preconditions @('Original operation completed.','Original action and rollback handler are available.','Target ownership and state are validated immediately before rollback.') -ApprovalRequired $true -SafeToAutomate $false -CurrentStatus 'PROPOSED' -RollbackInformation 'Recovery rollback itself requires manual review if interrupted.'
    Add-Member -InputObject $action -MemberType NoteProperty -Name RecoveryMetadata -Value $Assessment
    return $action
}

function New-RecoveryPlan {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Assessments)
    $actions=@()
    foreach($assessment in @($Assessments)) {
        if($assessment.RecoveryClass -eq 'Reversible') {$actions += New-RecoveryRollbackAction $assessment} else {$actions += New-RecoveryBlockedAction $assessment}
    }
    return @($actions)
}

function New-RecoveryHandler {
    [pscustomobject][ordered]@{
        TestPrecondition={param($action,$context)
            $m=$action.RecoveryMetadata
            if(-not $context.PSObject.Properties['RecoveryActions'] -or -not $context.RecoveryActions.ContainsKey($m.ActionId)){return [pscustomobject]@{Passed=$false;Failures=@('Original recovery action is unavailable.')}}
            if(-not $context.PSObject.Properties['RecoveryOperations'] -or -not $context.RecoveryOperations.ContainsKey($m.OperationId)){return [pscustomobject]@{Passed=$false;Failures=@('Original operation record is unavailable.')}}
            $original=$context.RecoveryActions[$m.ActionId];$operation=$context.RecoveryOperations[$m.OperationId];$handler=$context.RecoveryHandlerRegistry[$original.ActionType]
            if($operation.Status -ne 'Completed'){return [pscustomobject]@{Passed=$false;Failures=@('Automatic rollback is allowed only for a completed operation.')}}
            if(-not $handler -or -not $handler.PSObject.Properties['Rollback'] -or -not $handler.Rollback){return [pscustomobject]@{Passed=$false;Failures=@('Original handler has no rollback implementation.')}}
            return [pscustomobject]@{Passed=$true;Failures=@()}
        }
        Execute={param($action,$context)
            $m=$action.RecoveryMetadata;$original=$context.RecoveryActions[$m.ActionId];$operation=$context.RecoveryOperations[$m.OperationId];$handler=$context.RecoveryHandlerRegistry[$original.ActionType]
            $result=Invoke-ActionRollback $original $operation $handler $context
            if($result.Status -ne 'RolledBack'){throw ('Recovery rollback failed: '+[string]$result.Error)}
            if($result.Result -and $result.Result.PSObject.Properties['Status'] -and [string]$result.Result.Status -match 'Manual|RequiresExplicit'){throw 'Rollback handler returned manual-recovery status.'}
            [pscustomobject]@{Status='Recovered';OriginalOperationId=$m.OperationId;RecoveryInformation=$result.Result}
        }
        Rollback={param($action,$operation,$context)[pscustomobject]@{Status='ManualRecoveryRequired';RecoveryInformation='Recovery rollback is not automatically reversed.'}}
    }
}

function New-RecoveryHandlerRegistry {
    param([Parameter(Mandatory=$true)]$OriginalRegistry)
    $registry=New-ActionHandlerRegistry
    Register-ActionHandler $registry 'RECOVERY_ROLLBACK' (New-RecoveryHandler) | Out-Null
    return $registry
}

Export-ModuleMember -Function Get-RecoveryAssessment,New-RecoveryPlan,New-RecoveryHandler,New-RecoveryHandlerRegistry
