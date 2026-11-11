Set-StrictMode -Version 2.0

function Get-PlanActionType {
    param($Finding)
    if($Finding.Status -eq 'PASS') { return 'NO_ACTION' }
    if($Finding.Status -eq 'MISSING') { if($Finding.Component -match '^Directory ') { return 'CREATE_DIRECTORY' }; return 'ADD_OR_CONFIGURE' }
    if($Finding.Status -eq 'MISMATCH') { return 'REVIEW_OR_REPAIR' }
    if($Finding.Status -eq 'WARNING') { return 'REVIEW' }
    return 'INVESTIGATE'
}

function Get-PlanRisk {
    param([string]$ActionType,[string]$Component)
    if($ActionType -eq 'NO_ACTION') { return 'None' }
    if($Component -match 'Junction|PATH|Environment|Docker|WSL|Python user-site') { return 'High' }
    if($ActionType -eq 'CREATE_DIRECTORY' -or $ActionType -eq 'ADD_OR_CONFIGURE') { return 'Medium' }
    return 'Low'
}

function New-PlannedAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Component,
        [Parameter(Mandatory=$true)][string]$Description,
        [Parameter(Mandatory=$true)][string]$ActionType,
        [ValidateSet('None','Low','Medium','High')][string]$Risk = 'Low',
        [string[]]$AffectedPaths = @(),
        [string[]]$Preconditions = @(),
        [string[]]$Dependencies = @(),
        [bool]$ApprovalRequired = $true,
        [bool]$SafeToAutomate = $false,
        [string]$RollbackInformation = 'No mutation performed; retain the audit report as recovery context.',
        [ValidateSet('PROPOSED','NOT_REQUIRED','DISABLED','BLOCKED')][string]$CurrentStatus = 'PROPOSED',
        [string]$ActionId = ''
    )
    if([string]::IsNullOrWhiteSpace($ActionId)) { $ActionId = 'AUD-' + [guid]::NewGuid().ToString('N') }
    [pscustomobject][ordered]@{
        ActionId=$ActionId; Component=$Component; Description=$Description; ActionType=$ActionType; Risk=$Risk
        AffectedPaths=@($AffectedPaths); Preconditions=@($Preconditions); Dependencies=@($Dependencies)
        ApprovalRequired=$ApprovalRequired; SafeToAutomate=$SafeToAutomate; RollbackInformation=$RollbackInformation
        CurrentStatus=$CurrentStatus
    }
}

function New-PlanFromFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object[]]$Findings,
        [string[]]$DisabledComponents = @()
    )
    $actions=@(); $previousId=$null
    foreach($finding in $Findings) {
        $disabled=$false
        foreach($disabledComponent in $DisabledComponents) { if($finding.Component -like ($disabledComponent + '*')) {$disabled=$true} }
        $type=Get-PlanActionType $finding; $risk=Get-PlanRisk $type $finding.Component
        $status='PROPOSED'; $approval=$true; $description=$finding.RecommendedAction
        if($finding.Status -eq 'PASS') {$status='NOT_REQUIRED';$approval=$false;$description='No action required.'}
        if($disabled) {$status='DISABLED';$approval=$false;$description='No action planned because this component is disabled in configuration.'}
        $dependencies=@(); if($previousId -and $status -eq 'PROPOSED') {$dependencies=@($previousId)}
        $action=New-PlannedAction -Component $finding.Component -Description $description -ActionType $type -Risk $risk -AffectedPaths @($finding.ExpectedState,$finding.ActualState) -Preconditions @('Read-only audit completed.','Explicit approval is required before any future mutation.') -Dependencies $dependencies -ApprovalRequired $approval -SafeToAutomate ([bool]$finding.SafeToAutomate) -CurrentStatus $status
        $actions += $action
        if($status -eq 'PROPOSED') {$previousId=$action.ActionId}
    }
    return $actions
}

Export-ModuleMember -Function New-PlannedAction,New-PlanFromFindings
