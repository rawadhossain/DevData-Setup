$appRoot=Join-Path $PSScriptRoot '..\..\src\Applications';$core=Join-Path $PSScriptRoot '..\..\src\Core'
Import-Module (Join-Path $core 'Configuration.psm1') -Force
Import-Module (Join-Path $appRoot 'Configuration.psm1') -Force
Import-Module (Join-Path $core 'Configuration.psm1') -Force
Import-Module (Join-Path $core 'Executor.psm1') -Force

Describe 'Application and developer configuration adapters' {
  It 'keeps application binaries separate from profile metadata' {
    $app=[pscustomobject]@{id='vscode';configuration=[pscustomobject]@{profile=[pscustomobject]@{path='D:\Profile';relocationSupported=$true;mechanism='--user-data-dir';desiredPath=$null}}};$provider=[pscustomobject]@{GetPathState={param($p)[pscustomobject]@{Exists=$true}}};$inventory=Get-ApplicationProfileInventory $app $provider; $inventory.BinaryComponent | Should Be 'vscode';$inventory.ProfilePath | Should Be 'D:\Profile';$inventory.SecretContentsInspected | Should Be $false
  }

  It 'reports unsupported profile relocation without inventing a destination' {
    $app=[pscustomobject]@{id='claude';configuration=[pscustomobject]@{profile=[pscustomobject]@{path='C:\Users\Example\.claude';relocationSupported=$false;mechanism='Not supported by this adapter';desiredPath=$null}}};$inventory=Get-ApplicationProfileInventory $app; $inventory.RelocationSupported.ToString() | Should Be 'False';($null -eq $inventory.DesiredPath) | Should Be $true;$inventory.Mechanism | Should Match 'Not supported'
  }

  It 'merges managed JSON settings while preserving unrelated values and creating a backup' {
    $root=Join-Path $env:TEMP ('devdata-app-config-'+[guid]::NewGuid().ToString());New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {$state=[pscustomobject]@{Managed='old';Unrelated='preserve'};$written=@{Value=$null};$backup=Join-Path $root 'settings.bak';$provider=[pscustomobject]@{ReadJson={param($p)$state};WriteJson={param($p,$v)$written.Value=$v};Backup={param($p,$b)Set-Content -LiteralPath $backup -Value 'backup';$backup};Verify={param($p,$e)$true}};$path=Join-Path $root 'settings.json';Set-Content -LiteralPath $path -Value '{}';$action=New-ApplicationJsonConfigurationAction 'CONFIG-APP-test' 'test' $path ([ordered]@{Managed='new'});$registry=New-ActionHandlerRegistry;Register-ActionHandler $registry 'APPLICATION_CONFIGURE' (New-ApplicationJsonConfigurationHandler) | Out-Null;$context=[pscustomobject]@{AuditCompleted=$true;ApplicationConfigurationProvider=$provider;BackupRoot=$root};$result=@(Invoke-ExecutionPlan @($action) $registry (Join-Path $root 'journal.json') (Join-Path $root 'operations.jsonl') -Context $context -ApprovedActionIds $action.ActionId);$result[0].Status | Should Be 'Completed';$written.Value.Unrelated | Should Be 'preserve';$written.Value.Managed | Should Be 'new';(Test-Path -LiteralPath $backup) | Should Be $true
    } finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
  }

  It 'rejects credential-bearing configuration paths before reading them' {
    $action=New-ApplicationJsonConfigurationAction 'CONFIG-APP-secret' 'secret' 'C:\Users\Example\.docker\config.json' ([ordered]@{setting='value'});$check=& (New-ApplicationJsonConfigurationHandler).TestPrecondition $action ([pscustomobject]@{ApplicationConfigurationProvider=[pscustomobject]@{}});$check.Passed | Should Be $false;$check.Failures -join ';' | Should Match 'sensitive'
  }

  It 'builds environment, PATH and package-manager actions from desired configuration' {
    $config=Import-AuditConfiguration (Join-Path $PSScriptRoot '..\..\config');$plan=@(New-DeveloperConfigurationPlan $config);@($plan | Where-Object {$_.ActionType -eq 'ENVIRONMENT_SET'}).Count | Should BeGreaterThan 0;@($plan | Where-Object {$_.ActionType -eq 'PATH_ADD'}).Count | Should BeGreaterThan 0;@($plan | Where-Object {$_.ActionType -eq 'PACKAGE_MANAGER_CONFIGURE'}).Count | Should Be 3
  }
}
