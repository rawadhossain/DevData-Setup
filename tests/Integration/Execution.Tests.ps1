$core = Join-Path $PSScriptRoot '..\..\src\Core'
$safety = Join-Path $PSScriptRoot '..\..\src\Safety'
Import-Module (Join-Path $core 'Executor.psm1') -Force
Import-Module (Join-Path $core 'Planner.psm1') -Force
Import-Module (Join-Path $core 'State.psm1') -Force
Import-Module (Join-Path $core 'Logger.psm1') -Force
Import-Module (Join-Path $safety 'Backup.psm1') -Force
Import-Module (Join-Path $safety 'Rollback.psm1') -Force

function New-TestWorkspace {
  $root=Join-Path $env:TEMP ('devdata-execution-' + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  [pscustomobject]@{Root=$root;Journal=(Join-Path $root 'journal.json');Log=(Join-Path $root 'operations.jsonl');Context=[pscustomobject]@{AuditCompleted=$true;Calls=(New-Object System.Collections.ArrayList)}}
}
function New-TestAction { param([string]$Id,[string[]]$Dependencies=@(),[string]$Risk='None',[bool]$ApprovalRequired=$false,[string[]]$Preconditions=@('Test precondition'))
  New-PlannedAction -ActionId $Id -Component $Id -Description ('Execute '+$Id) -ActionType 'MOCK' -Risk $Risk -ApprovalRequired $ApprovalRequired -Dependencies $Dependencies -Preconditions $Preconditions
}
function New-MockRegistry {
  param($Context,[scriptblock]$TestPrecondition,[scriptblock]$Execute)
  $registry=New-ActionHandlerRegistry
  $handler=[pscustomobject]@{TestPrecondition=$TestPrecondition;Execute=$Execute;Rollback={param($a,$o,$c) 'rollback-ok'}}
  Register-ActionHandler $registry 'MOCK' $handler | Out-Null
  return $registry
}

Describe 'Execution engine' {
  It 'executes actions in dependency order' {
    $w=New-TestWorkspace;try{$context=$w.Context;$registry=New-MockRegistry $context $null {param($a,$c)[void]$c.Calls.Add($a.ActionId)};$a=New-TestAction 'A';$b=New-TestAction 'B' @('A');$result=@(Invoke-ExecutionPlan @($b,$a) $registry $w.Journal $w.Log -Context $context);($context.Calls -join ',') | Should Be 'A,B';@($result | Where-Object {$_.Status -eq 'Completed'}).Count | Should Be 2}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'supports dry-run and WhatIf without invoking handlers' {
    $w=New-TestWorkspace;try{$context=$w.Context;$registry=New-MockRegistry $context $null {throw 'handler must not run'};$a=New-TestAction 'DRY';$dry=@(Invoke-ExecutionPlan @($a) $registry $w.Journal $w.Log -Context $context -DryRun);$dry[0].Status | Should Be 'Skipped';$dry[0].SkipReason | Should Be 'DryRun';$what=@(Invoke-ExecutionPlan @($a) $registry $w.Journal $w.Log -Context $context -WhatIf);$what[0].Status | Should Be 'Skipped';$what[0].SkipReason | Should Be 'WhatIf'}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'enforces approval for risky actions' {
    $w=New-TestWorkspace;try{$context=$w.Context;$registry=New-MockRegistry $context $null {throw 'handler must not run'};$a=New-TestAction 'RISK' @() 'High' $true;$result=@(Invoke-ExecutionPlan @($a) $registry $w.Journal $w.Log -Context $context);$result[0].Status | Should Be 'Skipped';$result[0].SkipReason | Should Be 'ApprovalRequired'}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'fails before execution when handler preconditions fail' {
    $w=New-TestWorkspace;try{$context=$w.Context;$registry=New-MockRegistry $context {param($a,$c)[pscustomobject]@{Passed=$false;Failures=@('mock lock')}} {throw 'handler must not run'};$a=New-TestAction 'PRE';$result=@(Invoke-ExecutionPlan @($a) $registry $w.Journal $w.Log -Context $context -ApprovedActionIds 'PRE');$result[0].Status | Should Be 'Failed';$result[0].FailureKind | Should Be 'PreconditionFailed'}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'persists operation journal state' {
    $w=New-TestWorkspace;try{$context=$w.Context;$registry=New-MockRegistry $context $null {param($a,$c) 'done'};$a=New-TestAction 'JOURNAL';Invoke-ExecutionPlan @($a) $registry $w.Journal $w.Log -Context $context | Out-Null;$journal=Read-OperationJournal $w.Journal;$journal.Operations.Count | Should Be 1;$journal.Operations[0].Status | Should Be 'Completed'}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'detects interrupted operations and does not retry them' {
    $w=New-TestWorkspace;try{$journal=New-OperationJournal;$record=Add-OperationRecord $journal 'INT' 'Running' 'INT' 'MOCK' 'Started' $null $null $null;Write-OperationJournal $journal $w.Journal;$context=$w.Context;$registry=New-MockRegistry $context $null {throw 'must not retry'};$a=New-TestAction 'INT';$result=@(Invoke-ExecutionPlan @($a) $registry $w.Journal $w.Log -Context $context);$result[0].Status | Should Be 'Skipped';$result[0].SkipReason | Should Be 'InterruptedOperationRequiresRecovery';@($context.Calls).Count | Should Be 0}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'prevents duplicate execution after completion' {
    $w=New-TestWorkspace;try{$context=$w.Context;$registry=New-MockRegistry $context $null {param($a,$c)[void]$c.Calls.Add($a.ActionId)};$a=New-TestAction 'ONCE';Invoke-ExecutionPlan @($a) $registry $w.Journal $w.Log -Context $context | Out-Null;$second=@(Invoke-ExecutionPlan @($a) $registry $w.Journal $w.Log -Context $context);@($context.Calls).Count | Should Be 1;$second[0].SkipReason | Should Be 'AlreadyCompleted'}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'provides rollback metadata and rollback interface' {
    $w=New-TestWorkspace;try{$a=New-TestAction 'RB';$manifest=New-BackupManifest $a $w.Root @('D:\mock');$info=Get-RecoveryInformation $a $manifest;$info.RecoveryRequired | Should Be $true;$handler=[pscustomobject]@{Rollback={param($action,$operation,$context)'restored'}};$op=[pscustomobject]@{OperationId='op'};$rollback=Invoke-ActionRollback $a $op $handler $w.Context;$rollback.Status | Should Be 'RolledBack'}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}

  It 'sanitizes handler errors and structured log data' {
    $w=New-TestWorkspace;try{$context=$w.Context;$registry=New-MockRegistry $context $null {throw 'password=hunter2 token=abc123'};$a=New-TestAction 'ERR';$result=@(Invoke-ExecutionPlan @($a) $registry $w.Journal $w.Log -Context $context);$result[0].Status | Should Be 'Failed';$result[0].ErrorMessage | Should Not Match 'hunter2';$result[0].ErrorMessage | Should Not Match 'abc123';Write-StructuredLog (New-StructuredLogger $w.Log) Error 'Bearer abc123' -Data ([pscustomobject]@{ApiToken='secret'}) | Out-Null;$text=Get-Content -Raw $w.Log;$text | Should Not Match 'abc123';$text | Should Not Match 'secret'}finally{Remove-Item -LiteralPath $w.Root -Recurse -Force}}
}
