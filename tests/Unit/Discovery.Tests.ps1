$core = Join-Path $PSScriptRoot '..\..\src\Core'
Import-Module (Join-Path $core 'Configuration.psm1') -Force
Import-Module (Join-Path $core 'Discovery.psm1') -Force
Import-Module (Join-Path $core 'Comparison.psm1') -Force

Describe 'Discovery helpers' {
  It 'includes environment, PATH, package-manager and Go discovery in the normal machine audit' {
    $config=Import-AuditConfiguration (Join-Path $PSScriptRoot '..\..\config')
    $machine=Get-MachineDiscovery $config
    $machine.Environment.User | Should Not Be $null
    $machine.Environment.Machine | Should Not Be $null
    $machine.Environment.Process | Should Not Be $null
    $machine.Path.User | Should Not Be $null
    $machine.PackageManagers.Managers | Should Not Be $null
    $machine.Go.Environment | Should Not Be $null
  }

  It 'uses an injected package-manager provider without changing the host' {
    $provider=[pscustomobject]@{
      GetCommand={param($name) if($name -eq 'npm'){[pscustomobject]@{Source='mock-npm'}}else{$null}}
      Invoke={param($command,$arguments) if($arguments -contains '--version'){'mock-version'}else{'D:\mock'}}
      Set={throw 'discovery must not configure'}
    }
    $result=Get-PackageManagerDiscovery $provider
    ($result.Commands | Where-Object {$_.Name -eq 'npm'}).Available | Should Be $true
    ($result.Commands | Where-Object {$_.Name -eq 'pnpm'}).Available | Should Be $false
    $result.ConfigurationPaths['npm.prefix'] | Should Be 'D:\mock'
  }

  It 'discovers at least one filesystem drive without changing it' {
    $drives = @(Get-DriveDiscovery)
    $drives.Count | Should BeGreaterThan 0
    @($drives | Where-Object {$_.Root -eq 'C:\'}).Count | Should BeGreaterThan 0
  }

  It 'reports a missing directory without creating it' {
    $missing = Join-Path $env:TEMP ('devdata-audit-missing-' + [guid]::NewGuid().ToString())
    $metadata = Get-PathMetadata $missing
    $metadata.Exists | Should Be $false
    (Test-Path -LiteralPath $missing) | Should Be $false
  }

  It 'redacts secret-shaped environment names' {
    (ConvertTo-SafeEnvironmentValue 'EXAMPLE_TOKEN' 'do-not-log') | Should Be '[REDACTED]'
    (ConvertTo-SafeEnvironmentValue 'PATH' 'C:\safe') | Should Be 'C:\safe'
  }
}

Describe 'Comparison helpers' {
  It 'detects duplicate PATH entries from mock discovery data' {
    $path = [pscustomobject]@{User=[pscustomobject]@{Entries=@('D:\Go\bin','D:\Go\bin');Duplicates=@([pscustomobject]@{Normalized='d:\go\bin';Entries=@('D:\Go\bin','D:\Go\bin')});MalformedCandidates=@()};Machine=[pscustomobject]@{Duplicates=@();MalformedCandidates=@()}}
    $findings = @(Compare-PathRequirement $path @())
    @($findings | Where-Object {$_.Status -eq 'MISMATCH'}).Count | Should Be 1
  }

  It 'detects a duplicate PATH entry across user and machine scopes' {
    $path = [pscustomobject]@{User=[pscustomobject]@{Entries=@('D:\Node');Duplicates=@();MalformedCandidates=@()};Machine=[pscustomobject]@{Entries=@('D:\Node');Duplicates=@();MalformedCandidates=@()};CrossScopeDuplicates=@([pscustomobject]@{Normalized='d:\node';Entries=@([pscustomobject]@{Scope='User';Entry='D:\Node'},[pscustomobject]@{Scope='Machine';Entry='D:\Node'})})}
    $findings = @(Compare-PathRequirement $path @())
    @($findings | Where-Object {$_.Component -eq 'PATH cross-scope duplicate'}).Count | Should Be 1
  }

  It 'compares a configured junction target from mock discovery data' {
    $config = [pscustomobject]@{
      defaults=[pscustomobject]@{paths=[pscustomobject]@{DEVDataRoot='D:\DevData';ProjectsRoot='D:\Projects';DockerWslRoot='D:\Docker\wsl';UbuntuWslRoot='D:\WSL\Ubuntu'}}
      storage=[pscustomobject]@{roots=[pscustomobject]@{developerData='%DEVDataRoot%';projects='%ProjectsRoot%';goSdk='%DEVDataRoot%\GoSDK\go';goWorkspace='%DEVDataRoot%\Go';python='%DEVDataRoot%\Python';packageManagers='%DEVDataRoot%\PackageManagers';dockerWsl='%DockerWslRoot%';ubuntuWsl='%UbuntuWslRoot%'}}
      environment=[pscustomobject]@{path=[pscustomobject]@{user=@();machine=@()};variables=[pscustomobject]@{}}
      junctions=[pscustomobject]@{junctions=@([pscustomobject]@{source='D:\Source';target='D:\Expected'})}
    }
    $discovery = [pscustomobject]@{
      DeveloperDirectories=@([pscustomobject]@{Path='D:\DevData';Exists=$true},[pscustomobject]@{Path='D:\Projects';Exists=$true},[pscustomobject]@{Path='D:\DevData\GoSDK\go';Exists=$true},[pscustomobject]@{Path='D:\DevData\Go';Exists=$true},[pscustomobject]@{Path='D:\DevData\Python';Exists=$true},[pscustomobject]@{Path='D:\DevData\PackageManagers';Exists=$true},[pscustomobject]@{Path='D:\Docker\wsl';Exists=$true},[pscustomobject]@{Path='D:\WSL\Ubuntu';Exists=$true},[pscustomobject]@{Path='D:\Source';Exists=$true;LinkType='Junction';Target='D:\Wrong'})
      Path=[pscustomobject]@{User=[pscustomobject]@{Entries=@();Duplicates=@();MalformedCandidates=@()};Machine=[pscustomobject]@{Duplicates=@();MalformedCandidates=@()}}
      Environment=[pscustomobject]@{User=@{}}
      PythonUv=[pscustomobject]@{UserSite=$null}
      DockerWsl=[pscustomobject]@{Registrations=@()}
    }
    $finding = @(Compare-AuditState $config $discovery | Where-Object {$_.Component -eq 'Junction D:\Source'})
    $finding.Count | Should Be 1
    $finding[0].Status | Should Be 'MISMATCH'
  }

  It 'reports expected versus actual state as a missing finding' {
    $finding = New-AuditFinding 'Projects root' 'D:\Projects' 'Missing' 'MISSING' 'Create only after approval.' $false
    $finding.ExpectedState | Should Be 'D:\Projects'
    $finding.ActualState | Should Be 'Missing'
    $finding.Status | Should Be 'MISSING'
  }
}
