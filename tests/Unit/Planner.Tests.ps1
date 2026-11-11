$core = Join-Path $PSScriptRoot '..\..\src\Core'
Import-Module (Join-Path $core 'Planner.psm1') -Force
Import-Module (Join-Path $core 'Comparison.psm1') -Force
Import-Module (Join-Path $core 'Reporting.psm1') -Force
Import-Module (Join-Path $core 'Configuration.psm1') -Force

Describe 'Planner' {
  It 'creates complete actions with unique IDs' {
    $one = New-PlannedAction -Component 'A' -Description 'First' -ActionType 'REVIEW' -Risk High -AffectedPaths 'D:\A' -Preconditions 'Exists' -RollbackInformation 'Review only.'
    $two = New-PlannedAction -Component 'B' -Description 'Second' -ActionType 'REVIEW' -Risk Medium
    $one.ActionId | Should Not Be $two.ActionId
    @('ActionId','Component','Description','ActionType','Risk','AffectedPaths','Preconditions','Dependencies','ApprovalRequired','SafeToAutomate','RollbackInformation','CurrentStatus') | ForEach-Object { @($one.PSObject.Properties.Name -contains $_) | Should Be $true }
    $one.Risk | Should Be 'High'
    $one.ApprovalRequired | Should Be $true
  }

  It 'orders proposed actions through dependencies' {
    $findings=@(
      (New-AuditFinding 'First' 'x' 'y' 'MISMATCH' 'Review first.' $false),
      (New-AuditFinding 'Second' 'x' 'y' 'MISMATCH' 'Review second.' $false)
    )
    $plan=@(New-PlanFromFindings $findings)
    $plan.Count | Should Be 2
    @($plan[1].Dependencies -contains $plan[0].ActionId) | Should Be $true
    $plan[0].CurrentStatus | Should Be 'PROPOSED'
  }

  It 'suppresses disabled junction actions without executing them' {
    $finding=New-AuditFinding 'Junction C:\Example' 'D:\Target' 'Wrong' 'MISMATCH' 'Review junction.' $false
    $plan=@(New-PlanFromFindings @($finding) @('Junction'))
    $plan[0].CurrentStatus | Should Be 'DISABLED'
    $plan[0].ApprovalRequired | Should Be $false
    $plan[0].ActionType | Should Be 'REVIEW_OR_REPAIR'
  }
}

Describe 'Comparison coverage' {
  It 'compares configured versions' {
    $config=[pscustomobject]@{versions=[pscustomobject]@{constraints=[pscustomobject]@{node=[pscustomobject]@{minimum='20.0.0';maximum='30.0.0'}}}}
    $discovery=[pscustomobject]@{Tools=@([pscustomobject]@{Name='node';Path='D:\node.exe';Version='v26.13.0'})}
    $finding=@(Compare-Versions $config $discovery)
    $finding[0].Status | Should Be 'PASS'
  }

  It 'reports low drive capacity as an informational warning' {
    $config=[pscustomobject]@{defaults=[pscustomobject]@{paths=[pscustomobject]@{};driveCapacity=[pscustomobject]@{minimumFreeGB=10}};storage=[pscustomobject]@{roots=[pscustomobject]@{developerData='D:\DevData'}}}
    $discovery=[pscustomobject]@{Drives=@([pscustomobject]@{Name='D';FreeGB=2})}
    $finding=@(Compare-Drives $config $discovery)
    $finding[0].Status | Should Be 'WARNING'
    $finding[0].Classification | Should Be 'Informational'
  }

  It 'contains every baseline junction and no backup directory entry' {
    $config=Import-AuditConfiguration (Join-Path $PSScriptRoot '..\..\config')
    $junctions=@($config.junctions.junctions)
    $junctions.Count | Should Be 19
    $sources=@($junctions | ForEach-Object {Resolve-AuditValue $_.source $config})
    $targets=@($junctions | ForEach-Object {Resolve-AuditValue $_.target $config})
    $expectedSources=@(
      (Join-Path $env:USERPROFILE '.agents'),(Join-Path $env:USERPROFILE '.cache'),(Join-Path $env:USERPROFILE '.caveman'),(Join-Path $env:USERPROFILE '.claude'),(Join-Path $env:USERPROFILE '.copilot'),(Join-Path $env:USERPROFILE '.cursor'),(Join-Path $env:USERPROFILE '.docker'),(Join-Path $env:USERPROFILE '.gemini'),(Join-Path $env:USERPROFILE '.local'),(Join-Path $env:USERPROFILE '.vscode'),(Join-Path $env:USERPROFILE '.vscode-shared'),
      (Join-Path $env:USERPROFILE 'AppData\Local\claude-cli-nodejs'),(Join-Path $env:USERPROFILE 'AppData\Local\copilot'),(Join-Path $env:USERPROFILE 'AppData\Local\Cursor'),(Join-Path $env:USERPROFILE 'AppData\Local\npm-cache'),(Join-Path $env:USERPROFILE 'AppData\Local\uv'),(Join-Path $env:USERPROFILE 'AppData\Roaming\Code'),(Join-Path $env:USERPROFILE 'AppData\Roaming\Cursor'),(Join-Path $env:USERPROFILE 'AppData\Roaming\uv')
    )
    foreach($expected in $expectedSources){@($sources -contains $expected) | Should Be $true}
    ($sources -match '(?i)backup').Count | Should Be 0
    ($targets -match '(?i)backup').Count | Should Be 0
  }
}

Describe 'Report redaction' {
  It 'redacts sensitive property names and inline credential patterns' {
    $value=ConvertTo-SafeReportValue ([pscustomobject]@{ApiToken='secret-value';Message='Bearer abc123 password=hunter2';Path='D:\safe'})
    $value.ApiToken | Should Be '[REDACTED]'
    $value.Message | Should Not Match 'abc123'
    $value.Message | Should Not Match 'hunter2'
    $value.Path | Should Be 'D:\safe'
  }
}
