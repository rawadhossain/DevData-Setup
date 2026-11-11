Set-StrictMode -Version 2.0
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\Configuration.psm1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\Planner.psm1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\Executor.psm1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Environment\Variables.psm1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Environment\Path.psm1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Environment\PackageManagers.psm1')

function Test-ApplicationConfigurationPathSafe {
    param([Parameter(Mandatory=$true)][string]$Path)
    return ($Path -notmatch '(?i)(\\|/)(\.ssh|\.docker)(\\|/)|(?i)(credential|secret|token|password|auth|browser)')
}

function New-ApplicationConfigurationProvider {
    [pscustomobject][ordered]@{
        ReadJson={param($path)if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return $null};Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop}
        WriteJson={param($path,$value) $value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8}
        Backup={param($path,$backupRoot)if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return $null};if(-not (Test-Path -LiteralPath $backupRoot)){New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null};$backup=Join-Path $backupRoot ((Split-Path -Leaf $path)+'.'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak');Copy-Item -LiteralPath $path -Destination $backup -Force;return $backup}
        Verify={param($path,$expected)if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return $false};$actual=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json;return ((ConvertTo-Json $actual -Depth 20) -ne $null)}
    }
}

function ConvertTo-MergedConfigurationObject {
    param($Current,$Desired)
    if($Desired -is [System.Collections.IDictionary]){$result=[ordered]@{};if($Current){foreach($property in $Current.PSObject.Properties){$result[$property.Name]=$property.Value}};foreach($key in $Desired.Keys){$result[$key]=if($Current -and $Current.PSObject.Properties[$key]){ConvertTo-MergedConfigurationObject $Current.PSObject.Properties[$key].Value $Desired[$key]}else{$Desired[$key]}};return [pscustomobject]$result}
    if($Desired -and -not ($Desired -is [string]) -and @($Desired.PSObject.Properties).Count -gt 0 -and -not ($Desired -is [ValueType])){$result=[ordered]@{};if($Current){foreach($property in $Current.PSObject.Properties){$result[$property.Name]=$property.Value}};foreach($property in $Desired.PSObject.Properties){$result[$property.Name]=if($Current -and $Current.PSObject.Properties[$property.Name]){ConvertTo-MergedConfigurationObject $Current.PSObject.Properties[$property.Name].Value $property.Value}else{$property.Value}};return [pscustomobject]$result}
    return $Desired
}

function New-ApplicationJsonConfigurationAction {
    param([Parameter(Mandatory=$true)][string]$ActionId,[Parameter(Mandatory=$true)][string]$ApplicationId,[Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)]$Settings,[string[]]$Dependencies=@())
    $action=New-PlannedAction -ActionId $ActionId -Component ('Application '+$ApplicationId) -Description ('Update managed settings for '+$ApplicationId+'.') -ActionType 'APPLICATION_CONFIGURE' -Risk 'High' -AffectedPaths @($Path) -Preconditions @('Configuration path is safe and explicitly managed.','A backup provider is available.','Explicit approval is required.') -Dependencies $Dependencies -ApprovalRequired $true -SafeToAutomate $false -RollbackInformation 'Restore the provider-created configuration backup and verify the previous settings.'
    Add-Member -InputObject $action -MemberType NoteProperty -Name ApplicationConfigurationMetadata -Value ([pscustomobject][ordered]@{ApplicationId=$ApplicationId;Path=$Path;Settings=$Settings;Managed=$true})
    return $action
}

function New-ApplicationJsonConfigurationHandler {
    [pscustomobject][ordered]@{
        TestPrecondition={param($action,$context)
            $m=$action.ApplicationConfigurationMetadata;if(-not $m.Managed){return [pscustomobject]@{Passed=$false;Failures=@('Application settings are not explicitly managed.')}};if(-not (Test-ApplicationConfigurationPathSafe $m.Path)){return [pscustomobject]@{Passed=$false;Failures=@('Configuration path is sensitive or credential-bearing.')}};if(-not ($context -and $context.PSObject.Properties['ApplicationConfigurationProvider'] -and $context.ApplicationConfigurationProvider)){return [pscustomobject]@{Passed=$false;Failures=@('Application configuration provider is not supplied.')}};return [pscustomobject]@{Passed=$true;Failures=@()}
        }
        Execute={param($action,$context)
            $m=$action.ApplicationConfigurationMetadata;$p=$context.ApplicationConfigurationProvider;$before=& $p.ReadJson $m.Path;if($null -eq $before){throw 'Configuration file does not exist; creation is not enabled.'};$merged=ConvertTo-MergedConfigurationObject $before $m.Settings;if((ConvertTo-Json $before -Depth 20) -eq (ConvertTo-Json $merged -Depth 20)){return [pscustomobject]@{Status='AlreadyCorrect';RecoveryInformation='No configuration change required.'}};if(-not $p.PSObject.Properties['Backup']){throw 'Application configuration provider must expose Backup.'};$backup=& $p.Backup $m.Path $context.BackupRoot;if(-not $backup){throw 'Configuration backup was not created.'};& $p.WriteJson $m.Path $merged;if($p.PSObject.Properties['Verify']){if(-not (& $p.Verify $m.Path $merged)){throw 'Application configuration verification failed.'}};[pscustomobject]@{Status='Updated';BackupPath=$backup;RecoveryInformation=[pscustomobject]@{BackupPath=$backup;RestoreAction='Restore the provider-created backup and verify the prior settings.'}}
        }
        Rollback={param($action,$operation,$context) [pscustomobject]@{Status='RollbackRequiresExplicitRestore';RecoveryInformation='Restore the recorded application configuration backup with explicit approval.'}}
    }
}

function Get-ApplicationProfileInventory {
    param([Parameter(Mandatory=$true)]$Application,$Provider,$Configuration)
    $profile=$null;if($Application.PSObject.Properties['configuration'] -and $Application.configuration.PSObject.Properties['profile']){$profile=$Application.configuration.profile};$path=if($profile -and $profile.PSObject.Properties['path'] -and $profile.path){$rawPath=[string]$profile.path;if($Configuration){Resolve-AuditValue $rawPath $Configuration}else{$rawPath}}else{$null};$exists=$false;if($path -and $Provider -and $Provider.PSObject.Properties['GetPathState']){$exists=[bool]((& $Provider.GetPathState $path).Exists)}elseif($path){$exists=Test-Path -LiteralPath $path}
    [pscustomobject][ordered]@{ApplicationId=$Application.id;BinaryComponent=$Application.id;ProfilePath=$path;ProfileExists=$exists;RelocationSupported=if($profile -and $profile.PSObject.Properties['relocationSupported']){[string]$profile.relocationSupported}else{'Unknown'};Mechanism=if($profile -and $profile.PSObject.Properties['mechanism']){[string]$profile.mechanism}else{'Unknown'};DesiredPath=if($profile -and $profile.PSObject.Properties['desiredPath'] -and $null -ne $profile.desiredPath){[string]$profile.desiredPath}else{$null};SecretContentsInspected=$false}
}

function Get-DeveloperConfigurationInventory {
    param([Parameter(Mandatory=$true)]$Configuration,$ApplicationProvider)
    $variables=[ordered]@{};foreach($property in $Configuration.environment.variables.PSObject.Properties){$state=Get-EnvironmentVariableState $property.Name ([string]$Configuration.environment.scope);$safeName=if($property.Name -match '(?i)token|secret|password|credential|auth|private.?key|ssh|key'){'[REDACTED]'}else{$property.Name};$variables[$safeName]=[pscustomobject]@{Scope=$state.Scope;Exists=$state.Exists;Value=if($safeName -eq '[REDACTED]'){'[REDACTED]'}else{$state.Value}}}
    [pscustomobject][ordered]@{Variables=[pscustomobject]$variables;Path=Get-PathInspection 'User';PackageManagers=Get-PackageManagerConfiguration;Applications=@($Configuration.applications.applications | ForEach-Object {Get-ApplicationProfileInventory $_ $ApplicationProvider $Configuration})}
}

function New-DeveloperConfigurationPlan {
    param([Parameter(Mandatory=$true)]$Configuration)
    $actions=@();foreach($property in $Configuration.environment.variables.PSObject.Properties){$value=Resolve-AuditValue ([string]$property.Value) $Configuration;$actions+=New-EnvironmentVariableAction ('CONFIG-ENV-'+$property.Name) $property.Name ([string]$Configuration.environment.scope) $value 'Set'}
    foreach($path in @($Configuration.environment.path.user)){$resolved=Resolve-AuditValue ([string]$path) $Configuration;$safeId=($resolved -replace '[^A-Za-z0-9]','_');$actions+=New-PathAction ('CONFIG-PATH-'+$safeId) 'Add' 'User' $resolved}
    if($Configuration.environment.PSObject.Properties['packageManagers']){foreach($manager in $Configuration.environment.packageManagers.PSObject.Properties){if($manager.Name -notin @('npm','pnpm')){continue};foreach($setting in $manager.Value.PSObject.Properties){$resolved=Resolve-AuditValue ([string]$setting.Value) $Configuration;$actions+=New-PackageManagerConfigurationAction ('CONFIG-PM-'+$manager.Name+'-'+$setting.Name) $manager.Name $setting.Name $resolved}}}
    foreach($application in @($Configuration.applications.applications)){if(-not ($application.PSObject.Properties['configuration'] -and $application.configuration.PSObject.Properties['settings'])){continue};if(-not $application.configuration.settings.Count){continue};if($application.configuration.PSObject.Properties['settingsPath'] -and $application.configuration.settingsPath){$settings=[ordered]@{};foreach($setting in $application.configuration.settings){$settings[$setting.name]=$setting.value};$deps=@($application.dependencies | ForEach-Object {'CONFIG-APP-'+$_});$actions+=New-ApplicationJsonConfigurationAction ('CONFIG-APP-'+$application.id) $application.id (Resolve-AuditValue $application.configuration.settingsPath $Configuration) $settings $deps}}
    return $actions
}

function New-DeveloperConfigurationHandlerRegistry {
    $registry=New-ActionHandlerRegistry;Register-ActionHandler $registry 'ENVIRONMENT_SET' (New-EnvironmentVariableHandler) | Out-Null;Register-ActionHandler $registry 'PATH_ADD' (New-PathHandler) | Out-Null;Register-ActionHandler $registry 'PACKAGE_MANAGER_CONFIGURE' (New-PackageManagerHandler) | Out-Null;Register-ActionHandler $registry 'APPLICATION_CONFIGURE' (New-ApplicationJsonConfigurationHandler) | Out-Null;return $registry
}

Export-ModuleMember -Function Test-ApplicationConfigurationPathSafe,New-ApplicationConfigurationProvider,New-ApplicationJsonConfigurationAction,New-ApplicationJsonConfigurationHandler,Get-ApplicationProfileInventory,Get-DeveloperConfigurationInventory,New-DeveloperConfigurationPlan,New-DeveloperConfigurationHandlerRegistry
