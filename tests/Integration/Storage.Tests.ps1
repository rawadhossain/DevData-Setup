$core = Join-Path $PSScriptRoot '..\..\src\Core'
$storage = Join-Path $PSScriptRoot '..\..\src\Storage'
Import-Module (Join-Path $core 'Executor.psm1') -Force
Import-Module (Join-Path $core 'State.psm1') -Force
Import-Module (Join-Path $core 'Planner.psm1') -Force
Import-Module (Join-Path $storage 'Verification.psm1') -Force
Import-Module (Join-Path $storage 'Verification.psm1') -Force
Import-Module (Join-Path $storage 'Directories.psm1') -Force
Import-Module (Join-Path $storage 'Junctions.psm1') -Force
Import-Module (Join-Path $storage 'Migration.psm1') -Force
Import-Module (Join-Path $storage 'Verification.psm1') -Force

function New-StorageTestWorkspace {
  $root=Join-Path $env:TEMP ('devdata-storage-' + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  [pscustomobject]@{Root=$root;Journal=(Join-Path $root 'journal.json');Log=(Join-Path $root 'operations.jsonl');Context=[pscustomobject]@{AuditCompleted=$true;ApplicationProbe={param($a,$c)$false};RecoveryRecords=(New-Object System.Collections.ArrayList)}}
}
function Invoke-StorageAction {
  param($Action,$Handler,$Workspace,[string[]]$Approved=@())
  $registry=New-ActionHandlerRegistry;Register-ActionHandler $registry $Action.ActionType $Handler | Out-Null
  return @(Invoke-ExecutionPlan @($Action) $registry $Workspace.Journal $Workspace.Log -Context $Workspace.Context -ApprovedActionIds $Approved)
}

Describe 'Storage verification' {
  It 'distinguishes ordinary directories, correct junctions and wrong targets' {
    $w=New-StorageTestWorkspace;try{$ordinary=Join-Path $w.Root 'ordinary';$target=Join-Path $w.Root 'target';$other=Join-Path $w.Root 'other';New-Item -ItemType Directory -Path $ordinary,$target,$other | Out-Null;$ordinaryState=Test-JunctionState $ordinary $target;$ordinaryState.Status | Should Be 'OrdinaryDirectory';New-Item -ItemType Junction -Path (Join-Path $w.Root 'link') -Target $target | Out-Null;$correct=Test-JunctionState (Join-Path $w.Root 'link') $target;$correct.Status | Should Be 'Correct';$wrong=Test-JunctionState (Join-Path $w.Root 'link') $other;$wrong.Status | Should Be 'WrongTarget'}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'reports insufficient capacity without modifying the destination' {
    $w=New-StorageTestWorkspace;try{$result=Test-DirectoryCapacity $w.Root ([int64]::MaxValue);$result.Passed | Should Be $false;Test-Path -LiteralPath $w.Root | Should Be $true}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}
}

Describe 'Directory handler' {
  It 'creates a missing directory through the executor and is idempotent' {
    $w=New-StorageTestWorkspace;try{$path=Join-Path $w.Root 'created';$action=New-DirectoryCreationAction 'DIR-1' $path;$handler=New-DirectoryHandler;$first=Invoke-StorageAction $action $handler $w @('DIR-1');(Test-Path -LiteralPath $path -PathType Container) | Should Be $true;$first[0].Status | Should Be 'Completed';$second=Invoke-StorageAction $action $handler $w @('DIR-1');$second[0].SkipReason | Should Be 'AlreadyCompleted'}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'rejects an existing file conflict' {
    $w=New-StorageTestWorkspace;try{$path=Join-Path $w.Root 'conflict';New-Item -ItemType File -Path $path | Out-Null;$action=New-DirectoryCreationAction 'DIR-CONFLICT' $path;$result=Invoke-StorageAction $action (New-DirectoryHandler) $w @('DIR-CONFLICT');$result[0].Status | Should Be 'Failed';Test-Path -LiteralPath $path -PathType Leaf | Should Be $true}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}
}

Describe 'Junction handler' {
  It 'creates, validates and rolls back a temporary junction' {
    $w=New-StorageTestWorkspace;try{$target=Join-Path $w.Root 'target';$source=Join-Path $w.Root 'source';New-Item -ItemType Directory -Path $target | Out-Null;$action=New-JunctionAction 'J-1' $source $target;$handler=New-JunctionHandler;$result=Invoke-StorageAction $action $handler $w @('J-1');$result[0].Status | Should Be 'Completed';(Test-JunctionState $source $target).Status | Should Be 'Correct';$rollback=& $handler.Rollback $action $result[0] $w.Context;$rollback.Status | Should Be 'RemovedCreatedJunction';(Test-Path -LiteralPath $source) | Should Be $false}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'creates a repair plan without changing a wrong target' {
    $w=New-StorageTestWorkspace;try{$target=Join-Path $w.Root 'target';$wrong=Join-Path $w.Root 'wrong';$source=Join-Path $w.Root 'source';New-Item -ItemType Directory -Path $target,$wrong | Out-Null;New-Item -ItemType Junction -Path $source -Target $wrong | Out-Null;$plan=Get-JunctionRepairPlan $source $target;$plan.Needed | Should Be $true;$plan.Action.ActionType | Should Be 'JUNCTION_REPAIR';(Test-JunctionState $source $wrong).Status | Should Be 'Correct'}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}
}

Describe 'Transactional migration' {
  It 'migrates, verifies, preserves the original and creates a junction' {
    $w=New-StorageTestWorkspace;try{$source=Join-Path $w.Root 'source';$destination=Join-Path $w.Root 'destination';$backup=Join-Path $w.Root 'backup';New-Item -ItemType Directory -Path $source | Out-Null;Set-Content -LiteralPath (Join-Path $source 'data.txt') -Value 'safe';$action=New-MigrationAction 'M-1' $source $destination $backup;$w.Context | Add-Member -NotePropertyName CopyProvider -NotePropertyValue ({param($s,$d,$c)Copy-Item -Path (Join-Path $s '*') -Destination $d -Recurse -Force}).GetNewClosure();$result=Invoke-StorageAction $action (New-MigrationHandler) $w @('M-1');$result[0].Status | Should Be 'Completed';(Test-JunctionState $source $destination).Status | Should Be 'Correct';(Test-Path -LiteralPath $backup -PathType Container) | Should Be $true;Test-Path -LiteralPath (Join-Path $destination 'data.txt') -PathType Leaf | Should Be $true}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'fails safely when copy verification fails and preserves the source' {
    $w=New-StorageTestWorkspace;try{$source=Join-Path $w.Root 'source';$destination=Join-Path $w.Root 'destination';$backup=Join-Path $w.Root 'backup';New-Item -ItemType Directory -Path $source | Out-Null;Set-Content -LiteralPath (Join-Path $source 'data.txt') -Value 'safe';$action=New-MigrationAction 'M-FAIL' $source $destination $backup;$w.Context | Add-Member -NotePropertyName CopyProvider -NotePropertyValue ({param($s,$d,$c)}).GetNewClosure();$result=Invoke-StorageAction $action (New-MigrationHandler) $w @('M-FAIL');$result[0].Status | Should Be 'Failed';(Test-Path -LiteralPath $source -PathType Container) | Should Be $true;(Test-Path -LiteralPath $backup) | Should Be $false}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'detects an interrupted migration and does not retry it' {
    $w=New-StorageTestWorkspace;try{$source=Join-Path $w.Root 'source';$destination=Join-Path $w.Root 'destination';$backup=Join-Path $w.Root 'backup';New-Item -ItemType Directory -Path $source | Out-Null;$action=New-MigrationAction 'M-INT' $source $destination $backup;$journal=New-OperationJournal;Add-OperationRecord $journal 'M-INT' 'Running' 'Storage migration' 'DIRECTORY_MIGRATE' 'Started' $null $null $null | Out-Null;Write-OperationJournal $journal $w.Journal;$result=Invoke-StorageAction $action (New-MigrationHandler) $w @('M-INT');$result[0].Status | Should Be 'Skipped';$result[0].SkipReason | Should Be 'InterruptedOperationRequiresRecovery'}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'recovers a migrated source without deleting the destination' {
    $w=New-StorageTestWorkspace;try{$source=Join-Path $w.Root 'source';$destination=Join-Path $w.Root 'destination';$backup=Join-Path $w.Root 'backup';New-Item -ItemType Directory -Path $source | Out-Null;Set-Content -LiteralPath (Join-Path $source 'data.txt') -Value 'safe';$action=New-MigrationAction 'M-RB' $source $destination $backup;$w.Context | Add-Member -NotePropertyName CopyProvider -NotePropertyValue ({param($s,$d,$c)Copy-Item -Path (Join-Path $s '*') -Destination $d -Recurse -Force}).GetNewClosure();$execution=Invoke-StorageAction $action (New-MigrationHandler) $w @('M-RB');$execution[0].Status | Should Be 'Completed';(Get-StoragePathState $source).LinkType | Should Be 'Junction';(Test-Path -LiteralPath $backup -PathType Container) | Should Be $true;$recovery=[pscustomobject]@{Source=$source;Destination=$destination;BackupPath=$backup};$recoveryAction=New-MigrationRecoveryAction 'M-RB-RECOVER' $recovery;$result=Invoke-StorageAction $recoveryAction (New-MigrationRecoveryHandler) $w @('M-RB-RECOVER');$result[0].Status | Should Be 'Completed';Test-Path -LiteralPath (Join-Path $source 'data.txt') -PathType Leaf | Should Be $true;Test-Path -LiteralPath $destination -PathType Container | Should Be $true}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}
}
