Set-StrictMode -Version 2.0

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Discovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Comparison.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Planner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Executor.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Reporting.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'State.psm1') -Force
Import-Module (Join-Path $root 'Storage\Directories.psm1') -Force
Import-Module (Join-Path $root 'Storage\Migration.psm1') -Force
Import-Module (Join-Path $root 'Storage\Junctions.psm1') -Force
Import-Module (Join-Path $root 'Environment\Variables.psm1') -Force
Import-Module (Join-Path $root 'Environment\Path.psm1') -Force
Import-Module (Join-Path $root 'Environment\PackageManagers.psm1') -Force
Import-Module (Join-Path $root 'Applications\Configuration.psm1') -Force
Import-Module (Join-Path $root 'Install\Installation.psm1') -Force
Import-Module (Join-Path $root 'Infrastructure\DockerWsl.psm1') -Force

function Test-BootstrapConfiguration {
    param([Parameter(Mandatory=$true)]$Configuration)
    $failures=@()
    foreach($name in @('defaults','applications','storage','environment','junctions','versions')) {
        $present=$false
        if($Configuration -is [System.Collections.IDictionary]) { $present=$Configuration.Contains($name) } else { $present=($null -ne $Configuration.PSObject.Properties[$name]) }
        if(-not $present) { $failures += "Missing configuration section: $name" }
    }
    if($Configuration.storage -and -not $Configuration.storage.PSObject.Properties['roots']) { $failures += 'Storage roots are required.' }
    if($Configuration.environment -and -not $Configuration.environment.PSObject.Properties['variables']) { $failures += 'Environment variables section is required.' }
    [pscustomobject]@{Passed=($failures.Count -eq 0);Failures=@($failures)}
}

function Get-BootstrapDisabledComponents {
    param([Parameter(Mandatory=$true)]$Configuration)
    $disabled=@()
    if($Configuration.junctions.PSObject.Properties['enabled'] -and -not $Configuration.junctions.enabled) { $disabled += 'Junction' }
    if($Configuration.storage.PSObject.Properties['docker'] -and -not $Configuration.storage.docker.enabled) { $disabled += 'Docker' }
    if($Configuration.storage.PSObject.Properties['wsl'] -and -not $Configuration.storage.wsl.enabled) { $disabled += 'WSL' }
    foreach($application in @($Configuration.applications.applications)) {
        if($application.PSObject.Properties['enabled'] -and -not $application.enabled) { $disabled += ('Installation '+$application.id); $disabled += ('Application '+$application.id) }
    }
    return @($disabled)
}

function New-BootstrapBlockedAction {
    param([Parameter(Mandatory=$true)][string]$Component,[Parameter(Mandatory=$true)][string]$Description,[string[]]$AffectedPaths=@(),[string[]]$Dependencies=@())
    return New-PlannedAction -ActionId ('REVIEW-'+([guid]::NewGuid().ToString('N'))) -Component $Component -Description $Description -ActionType 'REVIEW_ONLY' -Risk 'Low' -AffectedPaths $AffectedPaths -Preconditions @('Manual review is complete.') -Dependencies $Dependencies -ApprovalRequired $false -SafeToAutomate $false -CurrentStatus 'BLOCKED' -RollbackInformation 'No mutation was performed; follow the review instruction.'
}

function Get-BootstrapDirectoryPlan {
    param($Configuration,$Discovery)
    $actions=@()
    foreach($property in $Configuration.storage.roots.PSObject.Properties) {
        $path=Resolve-AuditValue ([string]$property.Value) $Configuration
        $item=@($Discovery.DeveloperDirectories | Where-Object {$_.Path -eq $path} | Select-Object -First 1)
        if(-not $item.Count -or -not $item[0].Exists) {
            $id='DIRECTORY-'+($property.Name -replace '[^A-Za-z0-9]','-')
            $actions += New-DirectoryCreationAction $id $path
        }
    }
    return @($actions)
}

function Get-BootstrapJunctionPlan {
    param($Configuration,$Discovery)
    if($Configuration.junctions.PSObject.Properties['enabled'] -and -not $Configuration.junctions.enabled) { return @() }
    $actions=@()
    foreach($junction in @($Configuration.junctions.junctions)) {
        $source=Resolve-AuditValue ([string]$junction.source) $Configuration
        $target=Resolve-AuditValue ([string]$junction.target) $Configuration
        $state=Test-JunctionState $source $target
        if($state.Status -eq 'Correct') { continue }
        if($state.Status -eq 'Missing' -and (Test-Path -LiteralPath $target -PathType Container)) {
            $actions += New-JunctionAction ('JUNCTION-'+[string]$junction.id) $source $target
        } else {
            $actions += New-BootstrapBlockedAction ('Junction '+$source) ('Review junction state: '+$state.Message) @($source,$target)
        }
    }
    return @($actions)
}

function Test-BootstrapActionSatisfied {
    param($Action,$Discovery)
    if($Action.ActionType -eq 'DIRECTORY_CREATE') { $item=@($Discovery.DeveloperDirectories | Where-Object {$_.Path -eq $Action.StorageMetadata.Path} | Select-Object -First 1); return ($item.Count -and $item[0].Exists -and -not $item[0].LinkType) }
    if($Action.ActionType -eq 'JUNCTION_CREATE') { return ((Test-JunctionState $Action.StorageMetadata.Source $Action.StorageMetadata.Target).Status -eq 'Correct') }
    if($Action.ActionType -eq 'ENVIRONMENT_SET') { $scope=$Action.EnvironmentMetadata.Scope; $name=$Action.EnvironmentMetadata.Name; $actual=$null; if($Discovery.Environment.$scope -is [System.Collections.IDictionary] -and $Discovery.Environment.$scope.Contains($name)){$actual=[string]$Discovery.Environment.$scope[$name]} elseif($Discovery.Environment.$scope.PSObject.Properties[$name]){$actual=[string]$Discovery.Environment.$scope.PSObject.Properties[$name].Value}; return ([string]$actual -eq [string]$Action.EnvironmentMetadata.DesiredValue) }
    if($Action.ActionType -eq 'PATH_ADD') { $scope=$Action.PathMetadata.Scope; return (@($Discovery.Path.$scope.Entries | Where-Object {$_.TrimEnd('\') -ieq $Action.PathMetadata.Entry.TrimEnd('\')}).Count -gt 0) }
    if($Action.ActionType -eq 'PACKAGE_MANAGER_CONFIGURE') { $key=$Action.PackageManagerMetadata.Manager+'.'+$Action.PackageManagerMetadata.Setting; $actual=$null; if($Discovery.PackageManagers.ConfigurationPaths -is [System.Collections.IDictionary] -and $Discovery.PackageManagers.ConfigurationPaths.Contains($key)){$actual=[string]$Discovery.PackageManagers.ConfigurationPaths[$key]}; return ([string]$actual -ieq [string]$Action.PackageManagerMetadata.DesiredValue) }
    return $false
}

function Set-BootstrapActionStatus {
    param($Actions,$Discovery)
    foreach($action in @($Actions)) { if($action.CurrentStatus -notin @('DISABLED','BLOCKED','NOT_REQUIRED') -and (Test-BootstrapActionSatisfied $action $Discovery)) { $action.CurrentStatus='NOT_REQUIRED'; $action.Description='No action required; desired state is already present.'; $action.ApprovalRequired=$false } }
    return @($Actions)
}

function Get-BootstrapInfrastructurePlan {
    param($Configuration,$Discovery)
    $actions=@()
    if($Configuration.storage.PSObject.Properties['docker'] -and $Configuration.storage.docker.enabled -and $Configuration.storage.docker.relocation.enabled) { $actions += New-DockerStorageRelocationAction $Configuration }
    if($Configuration.storage.PSObject.Properties['wsl'] -and $Configuration.storage.wsl.enabled) {
        foreach($distribution in @($Configuration.storage.wsl.distributions)) {
            if($distribution.enabled -and $distribution.migration.enabled) {
                $name=[string]$distribution.name; $export=Join-Path (Resolve-AuditValue '%DEVDataRoot%' $Configuration) ('backups\wsl-'+$name+'.tar')
                $actions += New-WSLExportAction $name $export
                $actions += New-WSLImportAction $name $export (Resolve-AuditValue ([string]$distribution.destination) $Configuration) ([string]$distribution.version) 0 @('WSL-EXPORT-'+$name)
            }
        }
        $desired=[string]$Configuration.storage.wsl.defaultDistribution
        if($desired -and $Discovery.DockerWsl.WSL.DefaultDistribution -and $desired -ne $Discovery.DockerWsl.WSL.DefaultDistribution) { $actions += New-WSLDefaultDistributionAction $desired }
    }
    return @($actions)
}

function Test-BootstrapPlanConflicts {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Plan)
    $conflicts=@();$ids=@{}
    foreach($action in @($Plan)) { if($ids.ContainsKey($action.ActionId)){$conflicts += "Duplicate action ID: $($action.ActionId)"};$ids[$action.ActionId]=$true }
    for($i=0;$i -lt @($Plan).Count;$i++) { for($j=$i+1;$j -lt @($Plan).Count;$j++) { $left=@($Plan[$i].AffectedPaths);$right=@($Plan[$j].AffectedPaths);foreach($path in $left){$samePath=($right -contains $path);$pathAdd=([string]$Plan[$i].ActionType -like 'PATH_*' -and [string]$Plan[$j].ActionType -like 'PATH_*');if($samePath -and -not $pathAdd -and $Plan[$i].ActionType -ne 'REVIEW_ONLY' -and $Plan[$j].ActionType -ne 'REVIEW_ONLY'){$conflicts += "Conflicting actions share affected path: $path"}} } }
    [pscustomobject]@{Passed=($conflicts.Count -eq 0);Conflicts=@($conflicts)}
}

function New-BootstrapPlan {
    param([Parameter(Mandatory=$true)]$Configuration,[Parameter(Mandatory=$true)]$Discovery,[Parameter(Mandatory=$true)]$Findings,[string]$Component='')
    $actions=@();$actions += Get-BootstrapDirectoryPlan $Configuration $Discovery;$actions += New-DeveloperConfigurationPlan $Configuration;$actions += Get-InstallationPlan $Configuration $Discovery;$actions += Get-BootstrapJunctionPlan $Configuration $Discovery;$actions += Get-BootstrapInfrastructurePlan $Configuration $Discovery
    $actions=Set-BootstrapActionStatus $actions $Discovery
    $disabled=Get-BootstrapDisabledComponents $Configuration
    foreach($action in @($actions)) { foreach($prefix in $disabled) { if($action.Component -like ($prefix+'*')){$action.CurrentStatus='DISABLED';$action.Description='Disabled by configuration.';$action.ApprovalRequired=$false} } }
    if(-not [string]::IsNullOrWhiteSpace($Component)) { $actions=@($actions | Where-Object {$_.Component -like ('*'+$Component+'*') -or $_.ActionType -eq 'REVIEW_ONLY'}) }
    $conflicts=Test-BootstrapPlanConflicts $actions
    [pscustomobject]@{Actions=@($actions);Conflicts=$conflicts}
}

function New-BootstrapHandlerRegistry {
    $registry=New-ActionHandlerRegistry
    Register-ActionHandler $registry 'DIRECTORY_CREATE' (New-DirectoryHandler) | Out-Null
    Register-ActionHandler $registry 'JUNCTION_CREATE' (New-JunctionHandler) | Out-Null
    Register-ActionHandler $registry 'JUNCTION_REPAIR' (New-JunctionHandler) | Out-Null
    Register-ActionHandler $registry 'ENVIRONMENT_SET' (New-EnvironmentVariableHandler) | Out-Null
    Register-ActionHandler $registry 'ENVIRONMENT_REMOVE' (New-EnvironmentVariableHandler) | Out-Null
    Register-ActionHandler $registry 'PATH_ADD' (New-PathHandler) | Out-Null
    Register-ActionHandler $registry 'PATH_REMOVE' (New-PathHandler) | Out-Null
    Register-ActionHandler $registry 'PATH_REMOVEDUPLICATE' (New-PathHandler) | Out-Null
    Register-ActionHandler $registry 'PACKAGE_MANAGER_CONFIGURE' (New-PackageManagerHandler) | Out-Null
    Register-ActionHandler $registry 'APPLICATION_CONFIGURE' (New-ApplicationJsonConfigurationHandler) | Out-Null
    $install=New-InstallationHandlerRegistry; foreach($key in $install.Keys){$registry[$key]=$install[$key]}
    $infra=New-DockerWslHandlerRegistry; foreach($key in $infra.Keys){$registry[$key]=$infra[$key]}
    return $registry
}

function Get-BootstrapExitCode {
    param($ExecutionResults,$VerificationFindings,[bool]$DryRun,[bool]$PlanConflicted)
    if($PlanConflicted){return 3}
    if(@($ExecutionResults | Where-Object {$_.Status -eq 'Failed'}).Count -gt 0){return 1}
    if(-not $DryRun -and @($ExecutionResults | Where-Object {$_.SkipReason -eq 'ApprovalRequired'}).Count -gt 0){return 2}
    if(-not $DryRun -and @($VerificationFindings | Where-Object {$_.Status -eq 'MISMATCH' -or $_.Status -eq 'MISSING'}).Count -gt 0){return 1}
    return 0
}

function Invoke-BootstrapWorkflow {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string]$ConfigRoot,
        [string]$ReportPath,
        [switch]$DryRun,
        [switch]$Approve,
        [string]$Component,
        [hashtable]$Providers=@{},
        $Discovery,
        [string]$JournalPath,
        [string]$LogPath
    )
    $configuration=Import-AuditConfiguration $ConfigRoot;$validation=Test-BootstrapConfiguration $configuration;if(-not $validation.Passed){throw ($validation.Failures -join '; ')}
    $actual=if($null -ne $Discovery){$Discovery}else{Get-MachineDiscovery $configuration $Providers};$findings=@(Compare-AuditState $configuration $actual);$plan=New-BootstrapPlan $configuration $actual $findings $Component
    if($plan.Conflicts.Passed -eq $false){$results=@();$verification=$findings;$exit=3}
    else {
        if([string]::IsNullOrWhiteSpace($JournalPath)){$JournalPath=Join-Path $ConfigRoot '..\logs\operations.json'};if([string]::IsNullOrWhiteSpace($LogPath)){$LogPath=Join-Path $ConfigRoot '..\logs\operations.jsonl'}
        $context=[pscustomobject]@{AuditCompleted=$true;Configuration=$configuration};foreach($key in $Providers.Keys){$context | Add-Member -NotePropertyName $key -NotePropertyValue $Providers[$key] -Force}
        $registry=New-BootstrapHandlerRegistry
        $results=@()
        if(@($plan.Actions).Count){$results=@(Invoke-ExecutionPlan @($plan.Actions) $registry $JournalPath $LogPath -Context $context -DryRun:$DryRun -ApproveAll:$Approve -WhatIf:$WhatIfPreference)}
        $verification=if($DryRun -or $null -ne $Discovery){$findings}else{@(Compare-AuditState $configuration (Get-MachineDiscovery $configuration $Providers))};$exit=Get-BootstrapExitCode $results $verification ([bool]$DryRun) $false
    }
    if([string]::IsNullOrWhiteSpace($ReportPath)){$ReportPath=Join-Path $ConfigRoot '..\logs'}
    $report=ConvertTo-SafeReportObject $configuration $actual $findings $plan.Actions (Get-Date).ToString('o');$report | Add-Member NoteProperty Execution ([pscustomobject]@{Results=@($results);JournalPath=$JournalPath;ExitCode=$exit}) -Force;$report | Add-Member NoteProperty Verification ([pscustomobject]@{Findings=@($verification);Performed=(-not $DryRun)}) -Force;$written=Write-AuditReports $report $ReportPath
    [pscustomobject]@{ExitCode=$exit;Configuration=$configuration;Discovery=$actual;Findings=@($findings);Plan=@($plan.Actions);Conflicts=$plan.Conflicts;Execution=@($results);Verification=@($verification);Reports=$written}
}

Export-ModuleMember -Function Test-BootstrapConfiguration,Get-BootstrapDisabledComponents,Get-BootstrapDirectoryPlan,Get-BootstrapJunctionPlan,Get-BootstrapInfrastructurePlan,Test-BootstrapPlanConflicts,New-BootstrapPlan,New-BootstrapHandlerRegistry,Get-BootstrapExitCode,Invoke-BootstrapWorkflow
