Set-StrictMode -Version 2.0

function Get-EnvironmentVariableState {
    param([Parameter(Mandatory=$true)][string]$Name,[ValidateSet('User','Machine','Process')][string]$Scope='User')
    $value=[Environment]::GetEnvironmentVariable($Name,[EnvironmentVariableTarget]$Scope)
    [pscustomobject][ordered]@{Name=$Name;Scope=$Scope;Exists=($null -ne $value);Value=$value}
}

function Get-EnvironmentScopeSnapshot {
    param([ValidateSet('User','Machine','Process')][string]$Scope='User')
    $snapshot=[ordered]@{}
    foreach($entry in [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]$Scope).GetEnumerator()){
        $snapshot[$entry.Name]=[pscustomobject][ordered]@{Name=$entry.Name;Scope=$Scope;Exists=$true;Value=[string]$entry.Value}
    }
    return [pscustomobject]$snapshot
}

function New-EnvironmentProvider {
    [pscustomobject][ordered]@{
        Get={param($name,$scope) [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]$scope)}
        Set={param($name,$scope,$value) [Environment]::SetEnvironmentVariable($name,$value,[EnvironmentVariableTarget]$scope)}
        Remove={param($name,$scope) [Environment]::SetEnvironmentVariable($name,$null,[EnvironmentVariableTarget]$scope)}
        RefreshProcess={param($name,$scope,$value) [Environment]::SetEnvironmentVariable($name,$value,[EnvironmentVariableTarget]::Process)}
    }
}

function Get-EnvironmentProvider {
    param($Context)
    if($Context -and $Context.PSObject.Properties['EnvironmentProvider'] -and $Context.EnvironmentProvider){return $Context.EnvironmentProvider}
    return (New-EnvironmentProvider)
}

function New-EnvironmentVariableAction {
    param(
        [Parameter(Mandatory=$true)][string]$ActionId,
        [Parameter(Mandatory=$true)][string]$Name,
        [ValidateSet('User','Machine')][string]$Scope='User',
        [AllowNull()][string]$DesiredValue,
        [ValidateSet('Set','Remove')][string]$Operation='Set'
    )
    $type=if($Operation -eq 'Remove'){'ENVIRONMENT_REMOVE'}else{'ENVIRONMENT_SET'}
    [pscustomobject][ordered]@{
        ActionId=$ActionId;Component='Environment';Description="$Operation $Scope environment variable $Name";ActionType=$type
        Risk='High';AffectedPaths=@("${Scope}:$Name");Preconditions=@('Scope is valid','Variable is explicitly managed');Dependencies=@()
        ApprovalRequired=$true;SafeToAutomate=$false;RollbackInformation='Restore the captured previous value or remove the managed variable.';CurrentStatus='PLANNED'
        EnvironmentMetadata=[pscustomobject][ordered]@{Name=$Name;Scope=$Scope;DesiredValue=$DesiredValue;Operation=$Operation;Managed=$true}
    }
}

function New-EnvironmentVariableHandler {
    [pscustomobject][ordered]@{
        TestPrecondition={param($action,$context)
            $m=$action.EnvironmentMetadata
            if(-not $m.Managed){return [pscustomobject]@{Passed=$false;Failures=@('Only explicitly managed variables may be changed.')}}
            return [pscustomobject]@{Passed=$true;Failures=@()}
        }
        Execute={param($action,$context)
            $m=$action.EnvironmentMetadata;$p=Get-EnvironmentProvider $context
            $previous=& $p.Get $m.Name $m.Scope
            if($m.Operation -eq 'Remove'){
                if($null -eq $previous){return [pscustomobject]@{Status='AlreadyAbsent';RecoveryInformation='No previous value existed.'}}
                & $p.Remove $m.Name $m.Scope
                $expected=$null
            } else {
                if([string]$previous -eq [string]$m.DesiredValue){return [pscustomobject]@{Status='AlreadyCorrect';RecoveryInformation='No change required.'}}
                & $p.Set $m.Name $m.Scope $m.DesiredValue
                $expected=$m.DesiredValue
            }
            if($p.PSObject.Properties['RefreshProcess'] -and $m.Scope -ne 'Process'){& $p.RefreshProcess $m.Name $m.Scope $expected}
            $actual=& $p.Get $m.Name $m.Scope
            if($m.Operation -eq 'Remove'){if($null -ne $actual){throw "Environment variable '$($m.Name)' was not removed."}}
            elseif([string]$actual -ne [string]$m.DesiredValue){throw "Environment variable '$($m.Name)' did not persist the requested value."}
            [pscustomobject]@{Status='Updated';PersistenceVerified=$true;RecoveryInformation=[pscustomobject]@{Scope=$m.Scope;Name=$m.Name;PreviousValueCaptured=($null -ne $previous);RestoreAction='Create a reverse ENVIRONMENT_SET or ENVIRONMENT_REMOVE action.'}}
        }
        Rollback={param($action,$operation,$context) [pscustomobject]@{Status='RollbackRequiresExplicitRestoreAction';RecoveryInformation='Use the captured previous value from the operation result.'}}
    }
}

Export-ModuleMember -Function Get-EnvironmentVariableState,Get-EnvironmentScopeSnapshot,New-EnvironmentProvider,New-EnvironmentVariableAction,New-EnvironmentVariableHandler
