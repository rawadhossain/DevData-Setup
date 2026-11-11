$storage=Join-Path $PSScriptRoot '..\..\src\Storage'
$install=Join-Path $PSScriptRoot '..\..\src\Install'
Import-Module (Join-Path $PSScriptRoot '..\..\src\Core\Executor.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\src\Core\State.psm1') -Force
Import-Module (Join-Path $storage 'Migration.psm1') -Force
Import-Module (Join-Path $storage 'Verification.psm1') -Force
Import-Module (Join-Path $install 'OfficialInstallers.psm1') -Force

Describe 'Safety regression coverage' {
  It 'rejects nested migration paths before any copy or move' {
    $root=Join-Path $env:TEMP ('devdata-safety-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
      $source=Join-Path $root 'source';$destination=Join-Path $source 'destination';$backup=Join-Path $root 'backup';New-Item -ItemType Directory -Path $source | Out-Null
      $action=New-MigrationAction 'NESTED' $source $destination $backup;$result=Test-MigrationPrecondition $action ([pscustomobject]@{ApplicationProbe={ $false }})
      $result.Passed | Should Be $false;$result.Failures -join ';' | Should Match 'separate, non-nested';Test-Path -LiteralPath $destination | Should Be $false
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }

  It 'requires an executable verification path for official installers' {
    $app=[pscustomobject]@{id='tool';displayName='Tool';installation=[pscustomobject]@{method='ArchiveZip';source='https://example.invalid/tool.zip';sha256=('A'*64);destination=(Join-Path $env:TEMP 'devdata-empty-destination');executable=$null;version=$null;versionPolicy='Any'}}
    $action=New-OfficialInstallerAction $app;$result=& (New-OfficialInstallerHandler).TestPrecondition $action ([pscustomobject]@{})
    $result.Passed | Should Be $false;$result.Failures -join ';' | Should Match 'verification path'
  }

  It 'keeps an approved-action bypass attempt blocked by handler preconditions' {
    $handler=[pscustomobject]@{TestPrecondition={ [pscustomobject]@{Passed=$false;Failures=@('unsafe state')} };Execute={ throw 'must not execute' }}
    $action=[pscustomobject]@{ActionId='SAFE-1';Component='Safety';ActionType='MOCK';Risk='High';ApprovalRequired=$true;CurrentStatus='PROPOSED';Dependencies=@();Preconditions=@()}
    $registry=New-ActionHandlerRegistry;Register-ActionHandler $registry 'MOCK' $handler | Out-Null;$root=Join-Path $env:TEMP ('devdata-approval-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {$result=@(Invoke-ExecutionPlan @($action) $registry (Join-Path $root 'journal.json') (Join-Path $root 'log.jsonl') -Context ([pscustomobject]@{AuditCompleted=$true}) -ApproveAll);$result[0].Status | Should Be 'Failed';$result[0].FailureKind | Should Be 'PreconditionFailed'} finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
  }
}
