$envRoot=Join-Path $PSScriptRoot '..\..\src\Environment'
Import-Module (Join-Path $envRoot 'Variables.psm1') -Force
Import-Module (Join-Path $envRoot 'Path.psm1') -Force
Import-Module (Join-Path $envRoot 'PackageManagers.psm1') -Force

Describe 'Environment and package-manager handlers' {
  It 'reads user and machine scopes independently' {
    $user=Get-EnvironmentVariableState 'Path' 'User';$machine=Get-EnvironmentVariableState 'Path' 'Machine'
    $user.Scope | Should Be 'User';$machine.Scope | Should Be 'Machine'
  }

  It 'updates only the requested variable through a mock provider and refreshes process state' {
    $state=@{User=@{TEST_ONLY='old'};Process=@{TEST_ONLY='old'}};$calls=New-Object System.Collections.ArrayList
    $provider=[pscustomobject]@{Get={param($n,$s)$state[$s][$n]};Set={param($n,$s,$v)$state[$s][$n]=$v;[void]$calls.Add("set:$n")};Remove={param($n,$s)$state[$s].Remove($n)};RefreshProcess={param($n,$s,$v)$state.Process[$n]=$v;[void]$calls.Add("refresh:$n")}}
    $action=New-EnvironmentVariableAction 'ENV-1' 'TEST_ONLY' 'User' 'new' 'Set';$result=& (New-EnvironmentVariableHandler).Execute $action ([pscustomobject]@{EnvironmentProvider=$provider})
    $result.Status | Should Be 'Updated';$state.User.TEST_ONLY | Should Be 'new';$state.Process.TEST_ONLY | Should Be 'new';($calls -join ',') | Should Be 'set:TEST_ONLY,refresh:TEST_ONLY'
  }

  It 'does not remove an unrelated variable' {
    $provider=[pscustomobject]@{Get={param($n,$s)'present'};Set={};Remove={throw 'must not run'};RefreshProcess={}}
    $action=New-EnvironmentVariableAction 'ENV-2' 'UNRELATED' 'User' $null 'Remove';$action.EnvironmentMetadata.Managed=$false
    { & (New-EnvironmentVariableHandler).TestPrecondition $action ([pscustomobject]@{}) } | Should Not Throw
    (& (New-EnvironmentVariableHandler).TestPrecondition $action ([pscustomobject]@{})).Passed | Should Be $false
  }

  It 'detects duplicate and malformed PATH entries without changing them' {
    $inspection=Get-PathInspection 'User' 'C:\One;C:\One;D:\DevData\GoSDK\go\bin D:\DevData\Go\bin'
    $inspection.Duplicates.Count | Should Be 1;$inspection.MalformedCandidates.Count | Should Be 1
    (Normalize-PathEntry ' C:\One\ ').Normalized | Should Be 'C:\One'
  }

  It 'adds a PATH entry while preserving unrelated order and removes only managed duplicates' {
    $state=@{User='C:\First;C:\Second;C:\Second'};$provider=[pscustomobject]@{Get={param($s)$state[$s]};Set={param($s,$v)$state[$s]=$v};RefreshProcess={}}
    $handler=New-PathHandler;$add=New-PathAction 'PATH-1' 'Add' 'User' 'D:\Managed';(& $handler.Execute $add ([pscustomobject]@{PathProvider=$provider})).Status | Should Be 'Updated';$state.User | Should Be 'C:\First;C:\Second;C:\Second;D:\Managed'
    $remove=New-PathAction 'PATH-2' 'RemoveDuplicate' 'User' 'C:\Second';(& $handler.Execute $remove ([pscustomobject]@{PathProvider=$provider})).Status | Should Be 'Updated';$state.User | Should Be 'C:\First;C:\Second;D:\Managed'
  }

  It 'compares package-manager settings and distinguishes missing managers' {
    $expected=[pscustomobject]@{npm=[pscustomobject]@{prefix='D:\npm';cache='D:\cache'};pnpm=[pscustomobject]@{store='D:\store'}}
    $actual=[pscustomobject]@{npm=[pscustomobject]@{Available=$true;Settings=[pscustomobject]@{prefix='D:\npm';cache='C:\cache'}};pnpm=[pscustomobject]@{Available=$false;Settings=[pscustomobject]@{}}}
    $findings=@(Compare-PackageManagerConfiguration $expected $actual)
    @($findings | Where-Object Status -eq 'PASS').Count | Should Be 1;@($findings | Where-Object Status -eq 'MISMATCH').Count | Should Be 1;@($findings | Where-Object Status -eq 'MISSING').Count | Should Be 1
  }

  It 'does not configure a package manager when the provider reports the desired value' {
    $provider=[pscustomobject]@{GetCommand={param($n)[pscustomobject]@{Source=$n}};Invoke={param($c,$a)if($a -contains '--version'){'1.0'}else{'D:\desired'}};Set={throw 'must not run'}}
    $action=New-PackageManagerConfigurationAction 'PM-1' 'npm' 'prefix' 'D:\desired';$result=& (New-PackageManagerHandler).Execute $action ([pscustomobject]@{PackageManagerProvider=$provider});$result.Status | Should Be 'AlreadyCorrect'
  }
}
