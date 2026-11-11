Set-StrictMode -Version 2.0

function New-PreconditionResult { param([bool]$Passed,[string[]]$Failures=@(),[string[]]$Checks=@());[pscustomobject][ordered]@{Passed=$Passed;Failures=@($Failures);Checks=@($Checks);CheckedAt=(Get-Date).ToString('o')} }

function Test-ExecutionPreconditions {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Action,[Parameter(Mandatory=$true)]$Context,[AllowNull()]$Handler)
    $checks=@('Action exists')
    if($null -eq $Action){return New-PreconditionResult $false @('Action is null') $checks}
    $failures=@()
    if($Context.PSObject.Properties['AuditCompleted'] -and -not $Context.AuditCompleted){$failures+='Required audit completion was not confirmed.'}
    if($Handler -and $Handler.PSObject.Properties['TestPrecondition'] -and $Handler.TestPrecondition){
        try{$handlerResult=& $Handler.TestPrecondition $Action $Context;if($handlerResult -is [bool]){if(-not $handlerResult){$failures+='Handler precondition returned false.'}}elseif($handlerResult -and $handlerResult.PSObject.Properties['Passed'] -and -not $handlerResult.Passed){$failures+=@($handlerResult.Failures)}}catch{$failures+='Handler precondition failed: '+(Protect-PreconditionError $_)}
    }
    foreach($precondition in @($Action.Preconditions)){if([string]::IsNullOrWhiteSpace([string]$precondition)){continue};$checks+=[string]$precondition}
    return New-PreconditionResult ($failures.Count -eq 0) $failures $checks
}

function Protect-PreconditionError { param($Error);$message=if($Error.Exception){$Error.Exception.Message}else{[string]$Error};return ($message -replace '(?i)(bearer\s+)[^\s;]+','$1[REDACTED]' -replace '(?i)((?:token|secret|password|passwd|api[_-]?key|access[_-]?key)\s*[:=]\s*)[^\s,;]+','$1[REDACTED]') }
Export-ModuleMember -Function New-PreconditionResult,Test-ExecutionPreconditions
