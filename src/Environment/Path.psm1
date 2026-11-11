Set-StrictMode -Version 2.0

function Normalize-PathEntry {
    param([AllowNull()][string]$Entry)
    $original=$Entry;$value=if($null -eq $Entry){''}else{$Entry.Trim()}
    $value=$value.Trim('"').Trim()
    $expanded=[Environment]::ExpandEnvironmentVariables($value)
    $malformed=($expanded -match '\s+[A-Za-z]:\\' -or $expanded -match '\s+\\\\')
    if($expanded.Length -gt 3){$expanded=$expanded.TrimEnd('\')}
    [pscustomobject][ordered]@{Original=$original;Normalized=$expanded;IsEmpty=($expanded.Length -eq 0);IsMalformed=$malformed}
}

function Get-PathInspection {
    param([ValidateSet('User','Machine','Process')][string]$Scope='User',[string]$RawValue)
    if($PSBoundParameters.ContainsKey('RawValue')){$raw=$RawValue}else{$raw=[Environment]::GetEnvironmentVariable('Path',[EnvironmentVariableTarget]$Scope)}
    $entries=@();if($null -ne $raw){$entries=@($raw -split ';' | ForEach-Object {Normalize-PathEntry $_} | Where-Object {-not $_.IsEmpty})}
    $groups=@{};foreach($entry in $entries){$key=$entry.Normalized.ToLowerInvariant();if(-not $groups.ContainsKey($key)){$groups[$key]=@()};$groups[$key]+=$entry}
    $duplicates=@($groups.GetEnumerator() | Where-Object {$_.Value.Count -gt 1} | ForEach-Object {[pscustomobject]@{Normalized=$_.Key;Entries=@($_.Value)}})
    [pscustomobject][ordered]@{Scope=$Scope;RawValue=$raw;Entries=$entries;Duplicates=$duplicates;MalformedCandidates=@($entries | Where-Object {$_.IsMalformed})}
}

function New-PathProvider {
    [pscustomobject][ordered]@{
        Get={param($scope) [Environment]::GetEnvironmentVariable('Path',[EnvironmentVariableTarget]$scope)}
        Set={param($scope,$value) [Environment]::SetEnvironmentVariable('Path',$value,[EnvironmentVariableTarget]$scope)}
        RefreshProcess={param($value) [Environment]::SetEnvironmentVariable('Path',$value,[EnvironmentVariableTarget]::Process)}
    }
}

function New-PathAction {
    param([Parameter(Mandatory=$true)][string]$ActionId,[ValidateSet('Add','Remove','RemoveDuplicate')][string]$Operation='Add',[ValidateSet('User','Machine')][string]$Scope='User',[Parameter(Mandatory=$true)][string]$Entry)
    [pscustomobject][ordered]@{ActionId=$ActionId;Component='Path';Description="$Operation PATH entry";ActionType="PATH_$($Operation.ToUpperInvariant())";Risk='Medium';AffectedPaths=@("${Scope}:Path");Preconditions=@('Entry is explicitly managed');Dependencies=@();ApprovalRequired=$true;SafeToAutomate=$false;RollbackInformation='Restore the previous scoped PATH value.';CurrentStatus='PLANNED';PathMetadata=[pscustomobject][ordered]@{Scope=$Scope;Entry=$Entry;Operation=$Operation;Managed=$true}}
}

function New-PathHandler {
    [pscustomobject][ordered]@{
        TestPrecondition={param($action,$context) if(-not $action.PathMetadata.Managed){return [pscustomobject]@{Passed=$false;Failures=@('Only explicitly managed PATH entries may change.')}};return [pscustomobject]@{Passed=$true;Failures=@()}}
        Execute={param($action,$context)
            $m=$action.PathMetadata;$p=if($context -and $context.PSObject.Properties['PathProvider'] -and $context.PathProvider){$context.PathProvider}else{New-PathProvider};$raw=& $p.Get $m.Scope;$inspection=Get-PathInspection $m.Scope $raw;$target=(Normalize-PathEntry $m.Entry).Normalized
            if($m.Operation -eq 'Add'){
                if(@($inspection.Entries | Where-Object {$_.Normalized -ieq $target}).Count){return [pscustomobject]@{Status='AlreadyPresent';RecoveryInformation='No change required.'}}
                $new=@($inspection.Entries | ForEach-Object {$_.Original}) + @($m.Entry)
            } elseif($m.Operation -eq 'RemoveDuplicate'){
                if($inspection.MalformedCandidates | Where-Object {$_.Normalized -ieq $target}){throw 'Ambiguous malformed PATH entry cannot be removed automatically.'}
                $seen=$false;$new=@();foreach($entry in $inspection.Entries){if($entry.Normalized -ieq $target){if(-not $seen){$new+=$entry.Original;$seen=$true}}else{$new+=$entry.Original}}
                if($new.Count -eq $inspection.Entries.Count){return [pscustomobject]@{Status='AlreadyNormalized';RecoveryInformation='No duplicate required removal.'}}
            } else {
                if($inspection.MalformedCandidates | Where-Object {$_.Normalized -ieq $target}){throw 'Ambiguous malformed PATH entry cannot be removed automatically.'}
                $new=@($inspection.Entries | Where-Object {$_.Normalized -ine $target} | ForEach-Object {$_.Original})
                if($new.Count -eq $inspection.Entries.Count){return [pscustomobject]@{Status='AlreadyAbsent';RecoveryInformation='No change required.'}}
            }
            $joined=$new -join ';';& $p.Set $m.Scope $joined;if($p.PSObject.Properties['RefreshProcess']){& $p.RefreshProcess $joined};$verified=& $p.Get $m.Scope;if([string]$verified -ne [string]$joined){throw 'Scoped PATH did not persist the requested value.'}
            [pscustomobject]@{Status='Updated';RecoveryInformation=[pscustomobject]@{Scope=$m.Scope;PreviousValue=$raw;RestoreAction='Restore the previous scoped PATH value.'}}
        }
    }
}

Export-ModuleMember -Function Normalize-PathEntry,Get-PathInspection,New-PathProvider,New-PathAction,New-PathHandler
