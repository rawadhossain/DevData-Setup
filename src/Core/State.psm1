Set-StrictMode -Version 2.0

$script:OperationStatuses = @('Pending','Running','Completed','Failed','Skipped','RolledBack')

function New-OperationJournal {
    [pscustomobject][ordered]@{SchemaVersion=1;JournalId=([guid]::NewGuid().ToString('N'));CreatedAt=(Get-Date).ToString('o');UpdatedAt=(Get-Date).ToString('o');Operations=@()}
}

function Read-OperationJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return New-OperationJournal}
    try {$journal=Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop}catch{throw "Operation journal cannot be read: $($_.Exception.Message)"}
    if(-not $journal.PSObject.Properties['Operations']){$journal | Add-Member -NotePropertyName Operations -NotePropertyValue @()}
    return $journal
}

function Write-OperationJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Journal,[Parameter(Mandatory=$true)][string]$Path)
    $parent=Split-Path -Parent $Path;if($parent -and -not (Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force | Out-Null}
    $Journal.UpdatedAt=(Get-Date).ToString('o');$tempParent=if($parent){$parent}else{(Get-Location).Path};$temp=Join-Path $tempParent ('.'+(Split-Path -Leaf $Path)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        $Journal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temp -Encoding UTF8
        if(Test-Path -LiteralPath $Path -PathType Leaf){try{[IO.File]::Replace($temp,(Resolve-Path -LiteralPath $Path).Path,$null)}catch{Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop}}
        else {Move-Item -LiteralPath $temp -Destination $Path -Force:$false -ErrorAction Stop}
    } catch {if(Test-Path -LiteralPath $temp -PathType Leaf){Remove-Item -LiteralPath $temp -Force -Confirm:$false -ErrorAction SilentlyContinue};throw}
}

function Add-OperationRecord {
    param([Parameter(Mandatory=$true)]$Journal,[Parameter(Mandatory=$true)][string]$ActionId,[ValidateSet('Pending','Running','Completed','Failed','Skipped','RolledBack')][string]$Status,[string]$Component,[string]$ActionType,[string]$Message,[string]$ErrorMessage,[string]$SkipReason,[string]$FailureKind,[string]$PreviousOperationId)
    $record=[pscustomobject][ordered]@{OperationId=([guid]::NewGuid().ToString('N'));ActionId=$ActionId;Component=$Component;ActionType=$ActionType;Status=$Status;Message=$Message;ErrorMessage=$ErrorMessage;SkipReason=$SkipReason;FailureKind=$FailureKind;PreviousOperationId=$PreviousOperationId;StartedAt=(Get-Date).ToString('o');CompletedAt=if($Status -in @('Completed','Failed','Skipped','RolledBack')){(Get-Date).ToString('o')}else{$null}}
    $Journal.Operations=@($Journal.Operations)+@($record);return $record
}

function Update-OperationRecord {
    param([Parameter(Mandatory=$true)]$Journal,[Parameter(Mandatory=$true)][string]$OperationId,[ValidateSet('Pending','Running','Completed','Failed','Skipped','RolledBack')][string]$Status,[string]$Message,[string]$ErrorMessage,[string]$FailureKind,[string]$SkipReason)
    $record=@($Journal.Operations | Where-Object {$_.OperationId -eq $OperationId} | Select-Object -First 1);if(-not $record.Count){throw "Operation not found: $OperationId"};$record[0].Status=$Status;if($PSBoundParameters.ContainsKey('Message')){$record[0].Message=$Message};if($PSBoundParameters.ContainsKey('ErrorMessage')){$record[0].ErrorMessage=$ErrorMessage};if($PSBoundParameters.ContainsKey('FailureKind')){$record[0].FailureKind=$FailureKind};if($PSBoundParameters.ContainsKey('SkipReason')){$record[0].SkipReason=$SkipReason};if($Status -in @('Completed','Failed','Skipped','RolledBack')){$record[0].CompletedAt=(Get-Date).ToString('o')};return $record[0]
}

function Get-LatestOperation { param([Parameter(Mandatory=$true)]$Journal,[Parameter(Mandatory=$true)][string]$ActionId);return @($Journal.Operations | Where-Object {$_.ActionId -eq $ActionId} | Sort-Object StartedAt -Descending | Select-Object -First 1)}
function Get-InterruptedOperations { param([Parameter(Mandatory=$true)]$Journal);return @($Journal.Operations | Where-Object {$_.Status -eq 'Running'})}

Export-ModuleMember -Function New-OperationJournal,Read-OperationJournal,Write-OperationJournal,Add-OperationRecord,Update-OperationRecord,Get-LatestOperation,Get-InterruptedOperations
