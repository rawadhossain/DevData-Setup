Set-StrictMode -Version 2.0
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\Configuration.psm1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Storage\Verification.psm1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\Planner.psm1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\Executor.psm1')

function New-DockerWslProvider {
    [pscustomobject][ordered]@{
        GetCommand={param($name)Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1}
        Invoke={param($command,$arguments)try{(& $command.Source @arguments 2>&1 | Out-String).Trim()}catch{return $null}}
        GetVhdx={param($root)if(-not (Test-Path -LiteralPath $root -PathType Container)){return @()};@(Get-ChildItem -LiteralPath $root -Filter '*.vhdx' -File -Recurse -ErrorAction SilentlyContinue | Select-Object FullName,Length,LastWriteTime)}
        GetRegistryDistributions={
            $root='HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss';if(-not (Test-Path -LiteralPath $root)){return @()};@(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {$p=Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue;if($p){[pscustomobject][ordered]@{Name=$p.DistributionName;BasePath=$p.BasePath;Version=$p.Version;State=$p.State;Default=if($p.PSObject.Properties['Default']){[bool]$p.Default}else{$false}}}})
        }
        GetVirtualization={try{$computer=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop;$processor=Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1;[pscustomobject]@{VirtualizationFirmwareEnabled=$processor.VirtualizationFirmwareEnabled;SecondLevelAddressTranslationExtensions=$processor.SecondLevelAddressTranslationExtensions;HypervisorPresent=$computer.HypervisorPresent}}catch{[pscustomobject]@{VirtualizationFirmwareEnabled=$null;SecondLevelAddressTranslationExtensions=$null;HypervisorPresent=$null}}}
        GetFreeBytes={param($path)Get-StorageFreeBytes $path}
        Export={param($command,$name,$path)& $command.Source '--export' $name $path}
        Import={param($command,$name,$path,$destination,$version)& $command.Source '--import' $name $destination $path $version}
        SetDefault={param($command,$name)& $command.Source '--set-default' $name}
        GetDistribution={param($name)$root='HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss';if(-not (Test-Path $root)){return $null};$item=@(Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {$p=Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue;if($p -and $p.DistributionName -eq $name){[pscustomobject]@{Name=$p.DistributionName;BasePath=$p.BasePath;State=if($p.State -eq 1){'Running'}else{'Stopped'}}}} | Select-Object -First 1);if($item.Count){$item[0]}else{$null}}
    }
}

function Get-ProviderCommand { param($Provider,[string]$Name);return (& $Provider.GetCommand $Name) }
function Invoke-ProviderCommand { param($Provider,$Command,[string[]]$Arguments=@());if(-not $Command){return $null};return (& $Provider.Invoke $Command $Arguments) }

function Get-WSLDistributionList {
    param([string]$Text)
    $result=@();if([string]::IsNullOrWhiteSpace($Text)){return $result};foreach($line in ($Text -split "`r?`n")){if($line -match '^\s*(?<Default>\*)?\s*(?<Name>\S+)\s+(?<State>Running|Stopped|Installing|Uninstalling)\s+(?<Version>\d+)\s*$'){$result+=[pscustomobject][ordered]@{Name=$Matches.Name;State=$Matches.State;Version=[int]$Matches.Version;Default=([bool]$Matches.Default)}}};return $result
}

function Get-WSLDiscovery {
    param($Provider,$Configuration)
    if(-not $Provider){$Provider=New-DockerWslProvider};$command=Get-ProviderCommand $Provider 'wsl';$base=[ordered]@{Available=($null -ne $command);Path=if($command){$command.Source}else{$null};Version=$null;Status=$null;Distributions=@();DefaultDistribution=$null;Registrations=@();Virtualization=$null}
    if(-not $command){return [pscustomobject]$base};$base.Version=Invoke-ProviderCommand $Provider $command @('--version');$base.Status=Invoke-ProviderCommand $Provider $command @('--status');$listText=(Invoke-ProviderCommand $Provider $command @('--list','--verbose') | Out-String).Trim();$base.Distributions=@(Get-WSLDistributionList $listText);$default=@($base.Distributions | Where-Object {$_.Default} | Select-Object -First 1);if($default.Count){$base.DefaultDistribution=$default[0].Name};$base.Registrations=@(& $Provider.GetRegistryDistributions);$virtualization=& $Provider.GetVirtualization;$base.Virtualization=$virtualization
    foreach($registration in @($base.Registrations)){$match=@($base.Distributions | Where-Object {$_.Name -eq $registration.Name} | Select-Object -First 1);$vhdx=@();if($registration.BasePath){$vhdx=@(& $Provider.GetVhdx $registration.BasePath)};$registration | Add-Member -NotePropertyName Vhdx -NotePropertyValue $vhdx -Force;if($match.Count){$registration | Add-Member -NotePropertyName State -NotePropertyValue $match[0].State -Force;$registration | Add-Member -NotePropertyName WslVersion -NotePropertyValue $match[0].Version -Force}}
    return [pscustomobject]$base
}

function Get-DockerDiscovery {
    param($Provider,$Configuration,$WslState)
    if(-not $Provider){$Provider=New-DockerWslProvider};$command=Get-ProviderCommand $Provider 'docker';$configuredRoot=$null;$storage=$null;if($Configuration -is [System.Collections.IDictionary] -and $Configuration.Contains('storage')){$storage=$Configuration['storage']}elseif($Configuration -and $Configuration.PSObject.Properties['storage']){$storage=$Configuration.storage};if($storage -and $storage.PSObject.Properties['docker']){$configuredRoot=Resolve-AuditValue ([string]$storage.docker.dataRoot) $Configuration}elseif($storage -and $storage.PSObject.Properties['roots'] -and $storage.roots.PSObject.Properties['dockerWsl']){$configuredRoot=Resolve-AuditValue ([string]$storage.roots.dockerWsl) $Configuration};$configPath=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.docker';$base=[ordered]@{Available=($null -ne $command);Path=if($command){$command.Source}else{$null};Version=$null;DaemonAvailable=$false;DaemonDetails=$null;Contexts=@();ConfigDirectory=[pscustomobject]@{Path=$configPath;Exists=(Test-Path -LiteralPath $configPath -PathType Container)};ConfiguredStorageRoot=$configuredRoot;VirtualDisks=@();WslDistributions=@()}
    if($command){$base.Version=Invoke-ProviderCommand $Provider $command @('--version');$info=Invoke-ProviderCommand $Provider $command @('info');$base.DaemonDetails=$info;$base.DaemonAvailable=($null -ne $info -and [string]$info -notmatch '(?i)error|cannot connect|daemon is not running');$contextText=Invoke-ProviderCommand $Provider $command @('context','ls');if($contextText){$base.Contexts=@($contextText -split "`r?`n" | Where-Object {$_ -and $_ -notmatch '^\s*NAME\s+'})};if($configuredRoot){$base.VirtualDisks=@(& $Provider.GetVhdx $configuredRoot)}}
    if($WslState){$base.WslDistributions=@($WslState.Distributions | Where-Object {$_.Name -match '(?i)^docker-'})};return [pscustomobject]$base
}

function Get-DockerWslInfrastructureDiscovery {
    param($Configuration,$Provider)
    if(-not $Provider){$Provider=New-DockerWslProvider};$wsl=Get-WSLDiscovery $Provider $Configuration;$docker=Get-DockerDiscovery $Provider $Configuration $wsl;$wslListText=(@($wsl.Distributions | ForEach-Object {"$($_.Name) $($_.State) WSL$($_.Version)"}) -join "`r`n");[pscustomobject][ordered]@{Docker=$docker;WSL=$wsl;DockerPath=$docker.Path;DockerVersion=$docker.Version;DockerContexts=($docker.Contexts -join "`r`n");WslPath=$wsl.Path;WslStatus=$wsl.Status;WslList=$wslListText;Registrations=$wsl.Registrations}
}

function New-DockerStorageRelocationAction {
    param([Parameter(Mandatory=$true)]$Configuration)
    $root=Resolve-AuditValue ([string]$Configuration.storage.docker.dataRoot) $Configuration;$action=New-PlannedAction -ActionId 'DOCKER-STORAGE-RELOCATE' -Component 'Docker Desktop storage' -Description 'Relocate Docker Desktop storage using an officially supported Docker mechanism.' -ActionType 'DOCKER_STORAGE_RELOCATE' -Risk 'High' -AffectedPaths @($root) -Preconditions @('Docker Desktop is stopped.','Configured mechanism is supported by the installed Docker Desktop version.','Destination capacity is sufficient.','No VHDX is active.') -ApprovalRequired $true -SafeToAutomate $false -RollbackInformation 'Retain the original Docker Desktop storage and recovery metadata; do not delete or replace VHDX files automatically.';Add-Member -InputObject $action -MemberType NoteProperty -Name DockerMetadata -Value ([pscustomobject]@{Destination=$root;RequireStopped=$true;OfficialMechanismRequired=$true;Managed=$true});return $action
}

function New-WSLExportAction {
    param([Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][string]$ExportPath,[Int64]$RequiredBytes=0,[string[]]$Dependencies=@())
    $action=New-PlannedAction -ActionId ('WSL-EXPORT-'+$Name) -Component ('WSL '+$Name) -Description ('Export WSL distribution '+$Name+' to a retained recovery archive.') -ActionType 'WSL_EXPORT' -Risk 'High' -AffectedPaths @($ExportPath) -Preconditions @('Distribution is not running.','Export destination does not already exist.','Available capacity is sufficient.') -Dependencies $Dependencies -ApprovalRequired $true -SafeToAutomate $false -RollbackInformation 'Retain the export archive; original distribution remains registered.';Add-Member -InputObject $action -MemberType NoteProperty -Name WslMetadata -Value ([pscustomobject]@{Name=$Name;ExportPath=$ExportPath;RequiredBytes=$RequiredBytes;Managed=$true});return $action
}

function New-WSLImportAction {
    param([Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][string]$ExportPath,[Parameter(Mandatory=$true)][string]$Destination,[string]$Version='2',[Int64]$RequiredBytes=0,[string[]]$Dependencies=@())
    $action=New-PlannedAction -ActionId ('WSL-IMPORT-'+$Name) -Component ('WSL '+$Name) -Description ('Import WSL distribution '+$Name+' into the configured destination without removing the original.') -ActionType 'WSL_IMPORT' -Risk 'High' -AffectedPaths @($ExportPath,$Destination) -Preconditions @('Export archive is verified.','Destination is absent or empty.','Available capacity is sufficient.') -Dependencies $Dependencies -ApprovalRequired $true -SafeToAutomate $false -RollbackInformation 'Keep the original distribution and export archive; remove imported state only through a separate approved action.';Add-Member -InputObject $action -MemberType NoteProperty -Name WslMetadata -Value ([pscustomobject]@{Name=$Name;ExportPath=$ExportPath;Destination=$Destination;Version=$Version;RequiredBytes=$RequiredBytes;Managed=$true});return $action
}

function New-WSLDefaultDistributionAction {
    param([Parameter(Mandatory=$true)][string]$Name,[string[]]$Dependencies=@())
    $action=New-PlannedAction -ActionId ('WSL-DEFAULT-'+$Name) -Component 'WSL default distribution' -Description ('Set '+$Name+' as the default WSL distribution.') -ActionType 'WSL_SET_DEFAULT' -Risk 'Medium' -AffectedPaths @($Name) -Preconditions @('Target distribution is verified healthy.') -Dependencies $Dependencies -ApprovalRequired $true -SafeToAutomate $false -RollbackInformation 'Restore the previously recorded default distribution with explicit approval.';Add-Member -InputObject $action -MemberType NoteProperty -Name WslMetadata -Value ([pscustomobject]@{Name=$Name;Managed=$true});return $action
}

function New-WSLHandler {
    [pscustomobject][ordered]@{
        TestPrecondition={param($action,$context)$m=$action.WslMetadata;$p=$context.WslProvider;if(-not $p){return [pscustomobject]@{Passed=$false;Failures=@('WSL provider is not supplied.')}};if($action.ActionType -eq 'WSL_EXPORT'){if(-not $p.PSObject.Properties['GetDistribution']){return [pscustomobject]@{Passed=$false;Failures=@('WSL provider cannot inspect distribution state.')}};$d=& $p.GetDistribution $m.Name;if(-not $d){return [pscustomobject]@{Passed=$false;Failures=@('Distribution was not found.')}};if([string]$d.State -ne 'Stopped'){return [pscustomobject]@{Passed=$false;Failures=@('Distribution must be stopped before export.')}};if(Test-Path -LiteralPath $m.ExportPath){return [pscustomobject]@{Passed=$false;Failures=@('Export archive already exists; overwrite is prohibited.')}};if($m.RequiredBytes -gt 0 -and $p.PSObject.Properties['GetFreeBytes']){$free=& $p.GetFreeBytes (Split-Path -Qualifier $m.ExportPath);if($null -eq $free -or $free -lt $m.RequiredBytes){return [pscustomobject]@{Passed=$false;Failures=@('Insufficient capacity for WSL export.')}}}};if($action.ActionType -eq 'WSL_IMPORT' -and (Test-Path -LiteralPath $m.Destination)){return [pscustomobject]@{Passed=$false;Failures=@('Import destination already exists; overwrite is prohibited.')}};if($action.ActionType -eq 'WSL_IMPORT' -and $m.RequiredBytes -gt 0 -and $p.PSObject.Properties['GetFreeBytes']){$free=& $p.GetFreeBytes $m.Destination;if($null -eq $free -or $free -lt $m.RequiredBytes){return [pscustomobject]@{Passed=$false;Failures=@('Insufficient capacity for WSL import.')}}};[pscustomobject]@{Passed=$true;Failures=@()}}
        Execute={param($action,$context)$m=$action.WslMetadata;$p=$context.WslProvider;$getCommand=$p.PSObject.Properties['GetCommand'].Value;if(-not $getCommand){throw 'WSL provider cannot resolve commands.'};$command=& $getCommand 'wsl';if(-not $command){throw 'WSL executable is unavailable.'};if($action.ActionType -eq 'WSL_EXPORT'){$exportProvider=$p.PSObject.Properties['Export'].Value;if(-not $exportProvider){throw 'WSL provider cannot export distributions.'};& $exportProvider $command $m.Name $m.ExportPath | Out-Null;$verify=$p.PSObject.Properties['VerifyExport'];if($verify -and -not (& $verify.Value $m.ExportPath)){throw 'WSL export verification failed.'};return [pscustomobject]@{Status='Exported';BackupPath=$m.ExportPath;RecoveryInformation='Original distribution retained; export archive must not be deleted automatically.'}};if($action.ActionType -eq 'WSL_IMPORT'){$importProvider=$p.PSObject.Properties['Import'].Value;if(-not $importProvider){throw 'WSL provider cannot import distributions.'};& $importProvider $command $m.Name $m.ExportPath $m.Destination $m.Version | Out-Null;$verify=$p.PSObject.Properties['VerifyImport'];if($verify -and -not (& $verify.Value $m.Name $m.Destination)){throw 'WSL import verification failed.'};return [pscustomobject]@{Status='Imported';Destination=$m.Destination;RecoveryInformation='Original distribution and export archive retained.'}};$defaultProvider=$p.PSObject.Properties['SetDefault'].Value;if(-not $defaultProvider){throw 'WSL provider cannot set the default distribution.'};& $defaultProvider $command $m.Name | Out-Null;[pscustomobject]@{Status='DefaultChanged';Distribution=$m.Name;RecoveryInformation='Previous default must be restored explicitly if rollback is required.'}}
    }
}

function New-DockerStorageHandler {
    [pscustomobject][ordered]@{
        TestPrecondition={param($action,$context)$p=$context.DockerProvider;if(-not $p){return [pscustomobject]@{Passed=$false;Failures=@('Docker provider is not supplied.')}};$failures=@();if($p.PSObject.Properties['IsStopped'] -and -not (& $p.IsStopped)){ $failures+='Docker Desktop must be stopped.'};if(-not $p.PSObject.Properties['Relocate']){$failures+='No officially supported Docker relocation provider is registered.'};if($failures.Count){return [pscustomobject]@{Passed=$false;Failures=$failures}};[pscustomobject]@{Passed=$true;Failures=@()}}
        Execute={param($action,$context)$p=$context.DockerProvider;if(-not $p.PSObject.Properties['Relocate']){throw 'Docker relocation requires an explicit officially supported provider.'};$m=$action.DockerMetadata;& $p.Relocate $m.Destination;if($p.PSObject.Properties['Verify'] -and -not (& $p.Verify $m.Destination)){throw 'Docker storage relocation verification failed.'};[pscustomobject]@{Status='Relocated';Destination=$m.Destination;RecoveryInformation='Original Docker storage remains retained by the provider; no VHDX was directly moved.'}}
        Rollback={param($action,$operation,$context)[pscustomobject]@{Status='RollbackRequiresExplicitDockerProvider';RecoveryInformation='Use Docker Desktop supported settings to restore the recorded storage location.'}}
    }
}

function New-DockerWslHandlerRegistry {
    $registry=New-ActionHandlerRegistry;Register-ActionHandler $registry 'DOCKER_STORAGE_RELOCATE' (New-DockerStorageHandler) | Out-Null;$handler=New-WSLHandler;Register-ActionHandler $registry 'WSL_EXPORT' $handler | Out-Null;Register-ActionHandler $registry 'WSL_IMPORT' $handler | Out-Null;Register-ActionHandler $registry 'WSL_SET_DEFAULT' $handler | Out-Null;return $registry
}

Export-ModuleMember -Function New-DockerWslProvider,Get-WSLDistributionList,Get-WSLDiscovery,Get-DockerDiscovery,Get-DockerWslInfrastructureDiscovery,New-DockerStorageRelocationAction,New-WSLExportAction,New-WSLImportAction,New-WSLDefaultDistributionAction,New-WSLHandler,New-DockerStorageHandler,New-DockerWslHandlerRegistry
