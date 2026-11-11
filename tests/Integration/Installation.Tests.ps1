$root=Join-Path $PSScriptRoot '..\..\src\Install';$core=Join-Path $PSScriptRoot '..\..\src\Core'
Import-Module (Join-Path $root 'WinGet.psm1') -Force
Import-Module (Join-Path $root 'OfficialInstallers.psm1') -Force
Import-Module (Join-Path $root 'Installation.psm1') -Force
Import-Module (Join-Path $core 'Executor.psm1') -Force

function New-InstallWorkspace { $path=Join-Path $env:TEMP ('devdata-install-test-'+[guid]::NewGuid().ToString());New-Item -ItemType Directory -Path $path -Force | Out-Null;[pscustomobject]@{Root=$path;Journal=(Join-Path $path 'journal.json');Log=(Join-Path $path 'operations.jsonl')} }

Describe 'Software installation engine' {
  It 'discovers unavailable WinGet without throwing' {
    $provider=[pscustomobject]@{GetCommand={return $null};GetVersion={};Query={};Install={}}
    $state=Get-WinGetDiscovery $provider;$state.Available | Should Be $false;$state.Packages.Count | Should Be 0
  }

  It 'honors version policies' {
    (Test-DesiredVersion '1.2.3' '1.2.0' 'Minimum') | Should Be $true
    (Test-DesiredVersion '1.2.3' '1.2.3' 'Exact') | Should Be $true
    (Test-DesiredVersion '1.2.3' '1.2.4' 'Minimum') | Should Be $false
  }

  It 'executes a WinGet action through the existing executor and verifies the executable' {
    $w=New-InstallWorkspace;try {
      $state=@{Installed=$false};$provider=[pscustomobject]@{GetCommand={param($n)[pscustomobject]@{Source='mock-winget'}};GetVersion={param($c)'mock-winget 1.0'};Query={param($c,$id)if($state.Installed){[pscustomobject]@{PackageId=$id;Installed=$true;Version='1.2.3'}}else{$null}};Install={param($c,$id,$v)$state.Installed=$true};Verify={param($exe)[pscustomobject]@{Path=$exe;Version='tool 1.2.3'}}}
      $app=[pscustomobject]@{id='mock';displayName='Mock Tool';dependencies=@();installation=[pscustomobject]@{method='WinGet';packageId='Vendor.Mock';version='1.2.0';versionPolicy='Minimum';executable=[pscustomobject]@{command='mock-tool'}}};$action=New-WinGetInstallAction $app;$registry=New-ActionHandlerRegistry;Register-ActionHandler $registry 'INSTALL_WINGET' (New-WinGetHandler) | Out-Null;$context=[pscustomobject]@{AuditCompleted=$true;WinGetProvider=$provider};$result=@(Invoke-ExecutionPlan @($action) $registry $w.Journal $w.Log -Context $context -ApprovedActionIds $action.ActionId);$result[0].Status | Should Be 'Completed';$state.Installed | Should Be $true
    } finally {Remove-Item -LiteralPath $w.Root -Recurse -Force -ErrorAction SilentlyContinue}
  }

  It 'does not install over an existing package' {
    $provider=[pscustomobject]@{GetCommand={param($n)[pscustomobject]@{Source='mock-winget'}};GetVersion={param($c)'1.0'};Query={param($c,$id)[pscustomobject]@{PackageId=$id;Installed=$true;Version='9.0.0'}};Install={throw 'must not install'}};$app=[pscustomobject]@{id='existing';displayName='Existing';dependencies=@();installation=[pscustomobject]@{method='WinGet';packageId='Vendor.Existing';version='10.0.0';versionPolicy='Exact';executable=$null}};$action=New-WinGetInstallAction $app;$check=& (New-WinGetHandler).TestPrecondition $action ([pscustomobject]@{WinGetProvider=$provider});$check.Passed | Should Be $false;$check.Failures -join ';' | Should Match 'upgrade or downgrade'
  }

  It 'rejects unsafe official sources and missing hashes' {
    (Test-OfficialSource 'http://example.test/tool.zip') | Should Be $false
    $app=[pscustomobject]@{id='archive';displayName='Archive';dependencies=@();installation=[pscustomobject]@{method='ArchiveZip';source='https://example.test/tool.zip';sha256='';destination=(Join-Path $env:TEMP 'unused');executable='tool.exe'}};$action=New-OfficialInstallerAction $app;$check=& (New-OfficialInstallerHandler).TestPrecondition $action ([pscustomobject]@{});$check.Passed | Should Be $false;$check.Failures -join ';' | Should Match 'SHA256'
  }

  It 'executes a mocked official archive workflow without overwriting existing data' {
    $w=New-InstallWorkspace;try {$destination=Join-Path $w.Root 'tool';$provider=[pscustomobject]@{Download={param($s,$d)};GetFileHash={param($p)'ABC123'};ExtractZip={param($a,$d)New-Item -ItemType File -Path (Join-Path $d 'tool.exe') -Force | Out-Null};RunInstaller={};Verify={param($e,$a)[pscustomobject]@{Path=$e;Version='tool 1.0'}}};$app=[pscustomobject]@{id='archive';displayName='Archive';dependencies=@();installation=[pscustomobject]@{method='ArchiveZip';source='https://example.test/tool.zip';sha256='ABC123';destination=$destination;executable=(Join-Path $destination 'tool.exe');arguments=@();version='1.0';versionPolicy='Exact'}};$action=New-OfficialInstallerAction $app;$registry=New-ActionHandlerRegistry;Register-ActionHandler $registry 'INSTALL_OFFICIAL_ARCHIVE' (New-OfficialInstallerHandler) | Out-Null;$context=[pscustomobject]@{AuditCompleted=$true;OfficialInstallerProvider=$provider;TemporaryRoot=$w.Root};$result=@(Invoke-ExecutionPlan @($action) $registry $w.Journal $w.Log -Context $context -ApprovedActionIds $action.ActionId);$result[0].Status | Should Be 'Completed';(Test-Path -LiteralPath (Join-Path $destination 'tool.exe')) | Should Be $true
    } finally {Remove-Item -LiteralPath $w.Root -Recurse -Force -ErrorAction SilentlyContinue}
  }

  It 'does not plan unmanaged configured applications' {
    $config=[pscustomobject]@{applications=[pscustomobject]@{applications=@([pscustomobject]@{id='managed';displayName='Managed';enabled=$true;managed=$true;dependencies=@();installation=[pscustomobject]@{method='WinGet';packageId='Vendor.Managed';version=$null;versionPolicy='Any';executable=$null}},[pscustomobject]@{id='unmanaged';displayName='Unmanaged';enabled=$true;managed=$false;dependencies=@();installation=[pscustomobject]@{method='WinGet';packageId='Vendor.Unmanaged';version=$null;versionPolicy='Any';executable=$null}})}};$discovery=[pscustomobject]@{Tools=@()};$plan=@(Get-InstallationPlan $config $discovery);$plan.Count | Should Be 1;$plan[0].ActionId | Should Be 'INSTALL-managed'
  }

  It 'preserves configured installer dependencies in the plan' {
    $a=[pscustomobject]@{id='base';displayName='Base';enabled=$true;managed=$true;dependencies=@();installation=[pscustomobject]@{method='WinGet';packageId='Vendor.Base';version=$null;versionPolicy='Any';executable=$null}}
    $b=[pscustomobject]@{id='dependent';displayName='Dependent';enabled=$true;managed=$true;dependencies=@('base');installation=[pscustomobject]@{method='WinGet';packageId='Vendor.Dependent';version=$null;versionPolicy='Any';executable=$null}}
    $config=[pscustomobject]@{applications=[pscustomobject]@{applications=@($a,$b)}};$plan=@(Get-InstallationPlan $config ([pscustomobject]@{Tools=@()}));$plan[1].Dependencies | Should Be 'INSTALL-base'
  }
}
