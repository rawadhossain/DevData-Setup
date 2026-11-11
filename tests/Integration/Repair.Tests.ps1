$core=Join-Path $PSScriptRoot '..\..\src\Core'
$storage=Join-Path $PSScriptRoot '..\..\src\Storage'
Import-Module (Join-Path $core 'State.psm1') -Force -Global
Import-Module (Join-Path $core 'Planner.psm1') -Force -Global
Import-Module (Join-Path $core 'Executor.psm1') -Force -Global
Import-Module (Join-Path $core 'Recovery.psm1') -Force -Global
Import-Module (Join-Path $storage 'Junctions.psm1') -Force -Global
Import-Module (Join-Path $storage 'Verification.psm1') -Force -Global
Import-Module (Join-Path $core 'Repair.psm1') -Force -Global
Import-Module (Join-Path $core 'Recovery.psm1') -Force -Global
# Recovery imports shared modules in module scope. Re-export direct test helpers last.
Import-Module (Join-Path $core 'State.psm1') -Force -Global
Import-Module (Join-Path $core 'Planner.psm1') -Force -Global
Import-Module (Join-Path $core 'Executor.psm1') -Force -Global
Import-Module (Join-Path $storage 'Junctions.psm1') -Force -Global

function Invoke-TestState {
  param([string]$Name,[object[]]$Arguments=@())
  Import-Module (Join-Path $core 'State.psm1') -Force
  $command=Get-Command $Name -ErrorAction Stop
  & $command @Arguments
}

function New-RepairMockDiscovery {
  [pscustomobject][ordered]@{
    Windows=[pscustomobject]@{PowerShellVersion='5.1'};Drives=@();DeveloperDirectories=@();InstalledSoftware=@();Tools=@()
    Environment=[pscustomobject]@{User=@{};Machine=@{};Process=@{}}
    Path=[pscustomobject]@{User=[pscustomobject]@{Entries=@('T:\repair');Duplicates=@();MalformedCandidates=@()};Machine=[pscustomobject]@{Entries=@('T:\machine');Duplicates=@();MalformedCandidates=@()};Process=[pscustomobject]@{Entries=@('T:\process');Duplicates=@();MalformedCandidates=@()};CrossScopeDuplicates=@()}
    PackageManagers=[pscustomobject]@{ConfigurationPaths=@{};Managers=@();Commands=@()};PythonUv=[pscustomobject]@{PythonPath=$null;Version=$null;UserSite=$null;Prefix=$null};Go=[pscustomobject]@{Path=$null;Version=$null;Environment=@{}}
    DockerWsl=[pscustomobject]@{Docker=[pscustomobject]@{Available=$false;Path=$null;Version=$null;DaemonAvailable=$false;DaemonDetails=$null;VirtualDisks=@();WslDistributions=@()};WSL=[pscustomobject]@{Available=$false;Path=$null;Version=$null;Status=$null;Distributions=@();DefaultDistribution=$null;Registrations=@();Virtualization=$null};Registrations=@()}
  }
}

Describe 'Repair and recovery workflow' {
  It 'classifies interrupted destructive operations as manual recovery' {
    $journal=Invoke-TestState 'New-OperationJournal';$record=Invoke-TestState 'Add-OperationRecord' @($journal,'M-1','Running','Storage','MIGRATE_DIRECTORY','started',$null,$null,$null)
    $assessment=@(Recovery\Get-RecoveryAssessment $journal @())
    $assessment[0].RecoveryClass | Should Be 'ManualRecoveryRequired'
    $assessment[0].SafeToAutomate | Should Be $false
  }

  It 'creates a targeted reversible plan only for completed junction creation' {
    $journal=Invoke-TestState 'New-OperationJournal';$record=Invoke-TestState 'Add-OperationRecord' @($journal,'J-1','Completed','Junction','JUNCTION_CREATE','done',$null,$null,$null)
    $assessment=@(Recovery\Get-RecoveryAssessment $journal @([pscustomobject]@{ActionId='J-1';Component='Junction';ActionType='JUNCTION_CREATE';AffectedPaths=@('T:\source')}) $record.OperationId)
    $assessment[0].RecoveryClass | Should Be 'Reversible'
    $plan=@(Recovery\New-RecoveryPlan $assessment)
    $plan[0].ActionType | Should Be 'RECOVERY_ROLLBACK'
    $plan[0].ApprovalRequired | Should Be $true
  }

  It 'rolls back a completed temporary junction only after approval' {
    $root=Join-Path $env:TEMP ('devdata-recovery-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
      $target=Join-Path $root 'target';$source=Join-Path $root 'source';New-Item -ItemType Directory -Path $target | Out-Null;New-Item -ItemType Junction -Path $source -Target $target | Out-Null
      $original=Junctions\New-JunctionAction 'J-1' $source $target;$journal=Invoke-TestState 'New-OperationJournal';$record=Invoke-TestState 'Add-OperationRecord' @($journal,'J-1','Completed','Junction','JUNCTION_CREATE','done',$null,$null,$null)
      $assessment=@(Recovery\Get-RecoveryAssessment $journal @($original) $record.OperationId);$recovery=@(Recovery\New-RecoveryPlan $assessment)
      $originalRegistry=Executor\New-ActionHandlerRegistry;Executor\Register-ActionHandler $originalRegistry 'JUNCTION_CREATE' (Junctions\New-JunctionHandler) | Out-Null
      $registry=Recovery\New-RecoveryHandlerRegistry $originalRegistry;$context=[pscustomobject]@{RecoveryActions=@{'J-1'=$original};RecoveryOperations=@{$record.OperationId=$record};RecoveryHandlerRegistry=$originalRegistry}
      $journalPath=Join-Path $root 'journal.json';$logPath=Join-Path $root 'log.jsonl';Invoke-TestState 'Write-OperationJournal' @($journal,$journalPath)
      $blocked=@(Executor\Invoke-ExecutionPlan $recovery $registry $journalPath $logPath -Context $context)
      $blocked[0].SkipReason | Should Be 'ApprovalRequired';Test-Path -LiteralPath $source | Should Be $true
      $approved=@(Executor\Invoke-ExecutionPlan $recovery $registry $journalPath $logPath -Context $context -ApprovedActionIds $recovery[0].ActionId)
      $approved[0].Status | Should Be 'Completed';Test-Path -LiteralPath $source | Should Be $false
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }

  It 'runs Repair.ps1 workflow in dry-run using a mock discovery' {
    $root=Join-Path $env:TEMP ('devdata-repair-workflow-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
      $result=Invoke-RepairWorkflow -ConfigRoot (Join-Path $PSScriptRoot '..\..\config') -ReportPath (Join-Path $root 'reports') -JournalPath (Join-Path $root 'journal.json') -LogPath (Join-Path $root 'operations.jsonl') -Discovery (New-RepairMockDiscovery) -DryRun
      $result.ExitCode | Should Be 0
      Test-Path -LiteralPath $result.Reports.JsonPath -PathType Leaf | Should Be $true
      Test-Path -LiteralPath $result.Reports.MarkdownPath -PathType Leaf | Should Be $true
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
