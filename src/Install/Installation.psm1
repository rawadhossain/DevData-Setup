Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'WinGet.psm1')
Import-Module (Join-Path $PSScriptRoot 'OfficialInstallers.psm1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\Executor.psm1')

function Get-ConfiguredInstallationApplications {
    param([Parameter(Mandatory=$true)]$Configuration)
    if(-not $Configuration.applications.PSObject.Properties['applications']){return @()}
    return @($Configuration.applications.applications | Where-Object {$_.PSObject.Properties['installation'] -and $_.installation -and $_.installation.method -ne 'None'})
}

function Get-InstallationPlan {
    param([Parameter(Mandatory=$true)]$Configuration,[Parameter(Mandatory=$true)]$Discovery)
    $actions=@();$applications=Get-ConfiguredInstallationApplications $Configuration
    foreach($application in $applications){if($application.PSObject.Properties['enabled'] -and -not $application.enabled){continue};if($application.PSObject.Properties['managed'] -and -not $application.managed){continue};$existing=$null;$tool=@($Discovery.Tools | Where-Object {$_.Name -eq $application.id} | Select-Object -First 1);if($tool.Count){$existing=$tool[0]};if($application.installation.method -eq 'WinGet'){$actions+=New-WinGetInstallAction $application}else{$actions+=New-OfficialInstallerAction $application}}
    return $actions
}

function New-InstallationHandlerRegistry {
    $registry=New-ActionHandlerRegistry;Register-ActionHandler $registry 'INSTALL_WINGET' (New-WinGetHandler) | Out-Null;Register-ActionHandler $registry 'INSTALL_OFFICIAL_ARCHIVE' (New-OfficialInstallerHandler) | Out-Null;Register-ActionHandler $registry 'INSTALL_OFFICIAL_EXECUTABLE' (New-OfficialInstallerHandler) | Out-Null;return $registry
}

function Test-InstallationConfiguration {
    param([Parameter(Mandatory=$true)]$Application)
    $failures=@();$i=$Application.installation;if([string]::IsNullOrWhiteSpace([string]$i.method)){$failures+='Installation method is required.'};if($i.method -eq 'WinGet' -and [string]::IsNullOrWhiteSpace([string]$i.packageId)){$failures+='WinGet packageId is required.'};if($i.method -ne 'WinGet' -and -not (Test-OfficialSource ([string]$i.source))){$failures+='Official installer source must be HTTPS.'};return [pscustomobject]@{Passed=($failures.Count -eq 0);Failures=$failures}
}

Export-ModuleMember -Function Get-ConfiguredInstallationApplications,Get-InstallationPlan,New-InstallationHandlerRegistry,Test-InstallationConfiguration
