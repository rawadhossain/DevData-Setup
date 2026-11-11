$core = Join-Path $PSScriptRoot '..\..\src\Core'
Import-Module (Join-Path $core 'Bootstrap.psm1') -Force
Import-Module (Join-Path $core 'Configuration.psm1') -Force
Import-Module (Join-Path $core 'Planner.psm1') -Force

function New-BootstrapMockDiscovery {
  param([string[]]$ExistingPaths=@())
  [pscustomobject][ordered]@{
    Windows=[pscustomobject]@{PowerShellVersion='5.1'}
    Drives=@([pscustomobject]@{Name='T';FreeGB=100;FreeBytes=100GB;TotalBytes=200GB})
    DeveloperDirectories=@($ExistingPaths | ForEach-Object {[pscustomobject]@{Path=$_;Exists=$true;IsDirectory=$true;LinkType=$null;Target=$null}})
    InstalledSoftware=@()
    Tools=@()
    Environment=[pscustomobject]@{User=@{};Machine=@{};Process=@{}}
    Path=[pscustomobject]@{
      User=[pscustomobject]@{Entries=@('T:\\bootstrap-path');Duplicates=@();MalformedCandidates=@()}
      Machine=[pscustomobject]@{Entries=@('T:\\machine-path');Duplicates=@();MalformedCandidates=@()}
      Process=[pscustomobject]@{Entries=@('T:\\process-path');Duplicates=@();MalformedCandidates=@()}
      CrossScopeDuplicates=@()
    }
    PackageManagers=[pscustomobject]@{ConfigurationPaths=@{};Managers=@();Commands=@()}
    PythonUv=[pscustomobject]@{PythonPath=$null;Version=$null;UserSite=$null;Prefix=$null}
    Go=[pscustomobject]@{Path=$null;Version=$null;Environment=@{}}
    DockerWsl=[pscustomobject]@{
      Docker=[pscustomobject]@{Available=$false;Path=$null;Version=$null;DaemonAvailable=$false;DaemonDetails=$null;VirtualDisks=@();WslDistributions=@()}
      WSL=[pscustomobject]@{Available=$false;Path=$null;Version=$null;Status=$null;Distributions=@();DefaultDistribution=$null;Registrations=@();Virtualization=$null}
      Registrations=@()
    }
  }
}

Describe 'Bootstrap orchestration' {
  It 'runs a dry-run end to end and writes both reports' {
    $root=Join-Path $env:TEMP ('devdata-bootstrap-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
      $config=Join-Path $root 'config';New-Item -ItemType Directory -Path $config -Force | Out-Null
      Copy-Item (Join-Path $PSScriptRoot '..\..\config\*.json') $config
      $report=Join-Path $root 'reports';$discovery=New-BootstrapMockDiscovery
      $result=Invoke-BootstrapWorkflow -ConfigRoot $config -ReportPath $report -JournalPath (Join-Path $root 'journal.json') -LogPath (Join-Path $root 'operations.jsonl') -Discovery $discovery -DryRun
      $result.ExitCode | Should Be 0
      Test-Path -LiteralPath $result.Reports.JsonPath -PathType Leaf | Should Be $true
      Test-Path -LiteralPath $result.Reports.MarkdownPath -PathType Leaf | Should Be $true
      @($result.Plan).Count | Should BeGreaterThan 0
      @($result.Execution | Where-Object {$_.SkipReason -eq 'DryRun'}).Count | Should BeGreaterThan 0
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }

  It 'does not execute without explicit approval' {
    $root=Join-Path $env:TEMP ('devdata-bootstrap-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
      $config=Join-Path $root 'config';New-Item -ItemType Directory -Path $config -Force | Out-Null;Copy-Item (Join-Path $PSScriptRoot '..\..\config\*.json') $config
      $result=Invoke-BootstrapWorkflow -ConfigRoot $config -ReportPath (Join-Path $root 'reports') -JournalPath (Join-Path $root 'journal.json') -LogPath (Join-Path $root 'operations.jsonl') -Discovery (New-BootstrapMockDiscovery)
      $result.ExitCode | Should Be 2
      @($result.Execution | Where-Object {$_.SkipReason -eq 'ApprovalRequired'}).Count | Should BeGreaterThan 0
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }

  It 'marks already satisfied directory actions as not required' {
    $configuration=Import-AuditConfiguration (Join-Path $PSScriptRoot '..\..\config')
    $paths=@($configuration.storage.roots.PSObject.Properties | ForEach-Object {Resolve-AuditValue ([string]$_.Value) $configuration})
    $plan=Get-BootstrapDirectoryPlan $configuration (New-BootstrapMockDiscovery $paths)
    @($plan).Count | Should Be 0
  }

  It 'detects conflicting actions before execution' {
    $one=New-PlannedAction -ActionId 'ONE' -Component 'A' -Description 'A' -ActionType 'MOCK' -AffectedPaths 'T:\same'
    $two=New-PlannedAction -ActionId 'TWO' -Component 'B' -Description 'B' -ActionType 'MOCK' -AffectedPaths 'T:\same'
    $check=Test-BootstrapPlanConflicts @($one,$two)
    $check.Passed | Should Be $false
    $check.Conflicts[0] | Should Match 'same'
  }
}
