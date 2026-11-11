$infra=Join-Path $PSScriptRoot '..\..\src\Infrastructure';$core=Join-Path $PSScriptRoot '..\..\src\Core'
Import-Module (Join-Path $infra 'DockerWsl.psm1') -Force
Import-Module (Join-Path $core 'Executor.psm1') -Force
Import-Module (Join-Path $core 'Configuration.psm1') -Force
Import-Module (Join-Path $core 'Comparison.psm1') -Force

function New-DockerWslMockProvider {
  param([bool]$Available=$true,[string]$State='Stopped',[Int64]$FreeBytes=1000000000)
  $calls=New-Object System.Collections.ArrayList;$getCommand=if($Available){ {param($name)if($name -in @('docker','wsl')){[pscustomobject]@{Source=$name}}else{$null}} }else{ {param($name)$null} };$getDistribution=if($State -eq 'Stopped'){ {param($name)[pscustomobject]@{Name=$name;State='Stopped'}} }else{ {param($name)[pscustomobject]@{Name=$name;State='Running'}} }
  [pscustomobject]@{
    Calls=$calls
    GetCommand=$getCommand
    Invoke={param($command,$arguments)$key=($arguments -join ' ');if($command.Source -eq 'wsl' -and $key -eq '--version'){'WSL version: 2.4.0'}elseif($command.Source -eq 'wsl' -and $key -eq '--status'){'Default Distribution: Ubuntu'}elseif($command.Source -eq 'wsl' -and $key -eq '--list --verbose'){'  NAME      STATE           VERSION';'* Ubuntu   Stopped         2'}elseif($command.Source -eq 'docker' -and $key -eq '--version'){'Docker version 27.0.0'}elseif($command.Source -eq 'docker' -and $key -eq 'info'){'Server Version: 27.0.0'}elseif($command.Source -eq 'docker' -and $key -eq 'context ls'){'NAME        DESCRIPTION';'default     Current'}else{$null}}
    GetVhdx={param($root)[pscustomobject]@{FullName=(Join-Path $root 'ext4.vhdx');Length=12345;LastWriteTime=(Get-Date)}}
    GetRegistryDistributions={@([pscustomobject]@{Name='Ubuntu';BasePath='D:\WSL\Ubuntu';Version=2;State=1;Default=$true})}
    GetVirtualization={[pscustomobject]@{VirtualizationFirmwareEnabled=$true;SecondLevelAddressTranslationExtensions=$true;HypervisorPresent=$true}}
    GetFreeBytes={param($path)1000000000}
    Export={param($command,$name,$path)}
    Import={param($command,$name,$path,$destination,$version)}
    SetDefault={param($command,$name)}
    GetDistribution=$getDistribution
    VerifyExport={param($path)$true}
    VerifyImport={param($name,$destination)$true}
  }
}

Describe 'Docker and WSL infrastructure' {
  It 'discovers Docker, WSL, distributions, contexts and VHDX metadata' {
    $config=Import-AuditConfiguration (Join-Path $PSScriptRoot '..\..\config');$provider=New-DockerWslMockProvider;$state=Get-DockerWslInfrastructureDiscovery $config $provider
    $state.Docker.Available | Should Be $true;$state.Docker.DaemonAvailable | Should Be $true;$state.Docker.VirtualDisks.Count | Should Be 1;$state.WSL.Distributions[0].Name | Should Be 'Ubuntu';$state.WSL.Registrations[0].Vhdx.Count | Should Be 1
  }

  It 'handles unavailable Docker and WSL executables' {
    $state=Get-DockerWslInfrastructureDiscovery ([pscustomobject]@{}) (New-DockerWslMockProvider $false);$state.Docker.Available | Should Be $false;$state.WSL.Available | Should Be $false
  }

  It 'reports configured Docker and WSL audit findings' {
    $config=Import-AuditConfiguration (Join-Path $PSScriptRoot '..\..\config');$state=[pscustomobject]@{Docker=[pscustomobject]@{Available=$true;Path='D:\Docker\docker.exe';DaemonAvailable=$true;DaemonDetails='ok';VirtualDisks=@([pscustomobject]@{FullName='C:\Docker\ext4.vhdx'})};WSL=[pscustomobject]@{Available=$true;Path='C:\Windows\wsl.exe';DefaultDistribution='Ubuntu';Registrations=@([pscustomobject]@{Name='Ubuntu';BasePath='C:\Wrong';State='Stopped'});Virtualization=[pscustomobject]@{VirtualizationFirmwareEnabled=$true;SecondLevelAddressTranslationExtensions=$true}}};$discovery=[pscustomobject]@{DockerWsl=$state};$findings=@(Compare-DockerWslInfrastructure $config $discovery);@($findings | Where-Object {$_.Component -eq 'Docker configured storage root' -and $_.Status -eq 'MISMATCH'}).Count | Should Be 1;@($findings | Where-Object {$_.Component -eq 'WSL distribution Ubuntu storage' -and $_.Status -eq 'MISMATCH'}).Count | Should Be 1
  }

  It 'executes export/import through the Executor and retains recovery paths' {
    $root=Join-Path $env:TEMP ('devdata-wsl-'+[guid]::NewGuid().ToString());New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {$provider=New-DockerWslMockProvider;$export=New-WSLExportAction 'Ubuntu' (Join-Path $root 'ubuntu.tar') 100;$import=New-WSLImportAction 'Ubuntu' (Join-Path $root 'ubuntu.tar') (Join-Path $root 'ubuntu') '2' 100 @($export.ActionId);$registry=New-DockerWslHandlerRegistry;$context=[pscustomobject]@{AuditCompleted=$true;WslProvider=$provider};$result=@(Invoke-ExecutionPlan @($import,$export) $registry (Join-Path $root 'journal.json') (Join-Path $root 'operations.jsonl') -Context $context -ApproveAll);@($result | Where-Object {$_.Status -eq 'Completed'}).Count | Should Be 2
    } finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
  }

  It 'blocks export while a distribution is running and rejects insufficient capacity' {
    $root=Join-Path $env:TEMP ('devdata-wsl-'+[guid]::NewGuid().ToString());New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {$provider=New-DockerWslMockProvider $true 'Running' 1;$provider.GetFreeBytes={param($path)1};$action=New-WSLExportAction 'Ubuntu' (Join-Path $root 'ubuntu.tar') 100;$check=& (New-WSLHandler).TestPrecondition $action ([pscustomobject]@{WslProvider=$provider});$check.Passed | Should Be $false;$check.Failures -join ';' | Should Match 'stopped'
    } finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
  }

  It 'requires approval for Docker storage relocation' {
    $config=Import-AuditConfiguration (Join-Path $PSScriptRoot '..\..\config');$action=New-DockerStorageRelocationAction $config;$registry=New-DockerWslHandlerRegistry;$root=Join-Path $env:TEMP ('devdata-docker-'+[guid]::NewGuid().ToString());$result=@(Invoke-ExecutionPlan @($action) $registry (Join-Path $root 'journal.json') (Join-Path $root 'operations.jsonl') -Context ([pscustomobject]@{AuditCompleted=$true;DockerProvider=[pscustomobject]@{}}));$result[0].Status | Should Be 'Skipped';$result[0].SkipReason | Should Be 'ApprovalRequired'
  }
}
