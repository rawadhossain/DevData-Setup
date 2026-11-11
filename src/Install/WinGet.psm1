Set-StrictMode -Version 2.0
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\Planner.psm1') -Force

function ConvertTo-InstallVersion {
    param([AllowNull()][string]$Value)
    if([string]::IsNullOrWhiteSpace($Value)){return $null}
    $match=[regex]::Match($Value,'(?<!\d)(\d+(?:\.\d+){1,3})(?!\d)')
    if(-not $match.Success){return $null}
    try{return [version]$match.Groups[1].Value}catch{return $null}
}

function Test-DesiredVersion {
    param([AllowNull()][string]$Actual,[AllowNull()][string]$Desired,[string]$Policy='Any')
    if([string]::IsNullOrWhiteSpace($Desired) -or $Policy -eq 'Any'){return $true}
    $a=ConvertTo-InstallVersion $Actual;$d=ConvertTo-InstallVersion $Desired
    if($null -eq $a -or $null -eq $d){return $false}
    if($Policy -eq 'Minimum'){return $a -ge $d}
    return $a -eq $d
}

function New-WinGetProvider {
    [pscustomobject][ordered]@{
        GetCommand={Get-Command winget -ErrorAction SilentlyContinue | Select-Object -First 1}
        GetVersion={param($command) (& $command.Source '--version' 2>$null | Select-Object -First 1 | Out-String).Trim()}
        Query={param($command,$packageId) (& $command.Source 'list' '--id' $packageId '--exact' '--accept-source-agreements' '--disable-interactivity' 2>$null | Out-String).Trim()}
        Install={param($command,$packageId,$version) $args=@('install','--id',$packageId,'--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity');if($version){$args+=@('--version',$version)};& $command.Source @args}
        Verify={param($executable) $command=Get-Command $executable -ErrorAction SilentlyContinue | Select-Object -First 1;if(-not $command){return $null};[pscustomobject]@{Path=$command.Source;Version=((& $command.Source '--version' 2>$null | Select-Object -First 1 | Out-String).Trim())}}
    }
}

function ConvertFrom-WinGetListResult {
    param([string]$Text,[string]$PackageId)
    if([string]::IsNullOrWhiteSpace($Text) -or $Text -match '(?i)No package found|No installed package'){return $null}
    $lines=@($Text -split "`r?`n" | Where-Object {$_ -and $_ -notmatch '^-+$' -and $_ -notmatch '(?i)Name\s+Id\s+Version'})
    if(-not $lines.Count){return $null}
    $line=$lines | Where-Object {$_ -match [regex]::Escape($PackageId)} | Select-Object -First 1
    if(-not $line){$line=$lines[-1]}
    $version=$null;$match=[regex]::Match($line,'(?<!\d)(\d+(?:\.\d+){1,3})(?!\d)');if($match.Success){$version=$match.Groups[1].Value}
    [pscustomobject][ordered]@{PackageId=$PackageId;Installed=$true;Version=$version;Raw=$line}
}

function Get-WinGetDiscovery {
    param($Provider,[string[]]$PackageIds=@())
    if(-not $Provider){$Provider=New-WinGetProvider}
    $command=& $Provider.GetCommand
    if(-not $command){return [pscustomobject][ordered]@{Available=$false;Path=$null;Version=$null;Packages=@()}}
    $version=& $Provider.GetVersion $command
    $packages=@();foreach($id in $PackageIds){$package=Get-WinGetPackage $id $Provider;if($package){$packages+=$package}}
    [pscustomobject][ordered]@{Available=$true;Path=$command.Source;Version=$version;Packages=$packages}
}

function Get-WinGetPackage {
    param([Parameter(Mandatory=$true)][string]$PackageId,$Provider)
    if(-not $Provider){$Provider=New-WinGetProvider}
    $command=& $Provider.GetCommand;if(-not $command){return $null}
    $raw=& $Provider.Query $command $PackageId;if($raw -and $raw.PSObject.Properties['Installed']){return $raw};return (ConvertFrom-WinGetListResult ([string]$raw) $PackageId)
}

function New-WinGetInstallAction {
    param([Parameter(Mandatory=$true)]$Application)
    $install=$Application.installation
    $id='INSTALL-'+[string]$Application.id
    $action=New-PlannedAction -ActionId $id -Component ('Installation '+$Application.id) -Description ('Install '+$Application.displayName+' with WinGet.') -ActionType 'INSTALL_WINGET' -Risk 'High' -AffectedPaths @($install.packageId) -Preconditions @('WinGet is available.','No conflicting installed version exists.','Installation approval is explicit.') -Dependencies @($Application.dependencies | ForEach-Object {'INSTALL-'+[string]$_}) -ApprovalRequired $true -SafeToAutomate $false -RollbackInformation 'WinGet installations are not automatically uninstalled; record the installed package and use an explicit recovery decision.'
    Add-Member -InputObject $action -MemberType NoteProperty -Name InstallationMetadata -Value ([pscustomobject][ordered]@{Method='WinGet';ApplicationId=$Application.id;DisplayName=$Application.displayName;PackageId=$install.packageId;DesiredVersion=$install.version;VersionPolicy=$install.versionPolicy;Executable=$install.executable;Managed=$true})
    return $action
}

function New-WinGetHandler {
    [pscustomobject][ordered]@{
        TestPrecondition={param($action,$context)
            $p=if($context -and $context.PSObject.Properties['WinGetProvider'] -and $context.WinGetProvider){$context.WinGetProvider}else{New-WinGetProvider};$command=& $p.GetCommand
            if(-not $command){return [pscustomobject]@{Passed=$false;Failures=@('WinGet is unavailable.')}}
            $m=$action.InstallationMetadata;$existing=Get-WinGetPackage $m.PackageId $p
            if($existing -and $existing.Installed){if(Test-DesiredVersion $existing.Version $m.DesiredVersion $m.VersionPolicy){return [pscustomobject]@{Passed=$true;Failures=@()}};return [pscustomobject]@{Passed=$false;Failures=@('A different package version is installed; upgrade or downgrade is not automatic.')}}
            [pscustomobject]@{Passed=$true;Failures=@()}
        }
        Execute={param($action,$context)
            $p=if($context -and $context.PSObject.Properties['WinGetProvider'] -and $context.WinGetProvider){$context.WinGetProvider}else{New-WinGetProvider};$m=$action.InstallationMetadata;$before=Get-WinGetPackage $m.PackageId $p;if($before -and $before.Installed){if(Test-DesiredVersion $before.Version $m.DesiredVersion $m.VersionPolicy){return [pscustomobject]@{Status='AlreadyInstalled';PackageId=$m.PackageId;Version=$before.Version;RecoveryInformation='No installation performed; desired package state already exists.'}};throw 'Existing package state must be reviewed before installation.'};$command=& $p.GetCommand;if(-not $command){throw 'WinGet is unavailable.'};$output=& $p.Install $command $m.PackageId $m.DesiredVersion;$after=Get-WinGetPackage $m.PackageId $p;if(-not $after -or -not $after.Installed){throw "WinGet installation did not verify for '$($m.PackageId)'."};if(-not (Test-DesiredVersion $after.Version $m.DesiredVersion $m.VersionPolicy)){throw "Installed version '$($after.Version)' does not satisfy the desired policy."};$verification=$null;if($m.Executable -and $p.PSObject.Properties['Verify']){$commandName=if($m.Executable -is [string]){[string]$m.Executable}elseif($m.Executable.PSObject.Properties['command']){[string]$m.Executable.command}else{$null};if($commandName){$verification=& $p.Verify $commandName;if(-not $verification){throw "Executable verification failed for '$commandName'."}}};[pscustomobject]@{Status='Installed';PackageId=$m.PackageId;Version=$after.Version;Verification=$verification;RecoveryInformation=[pscustomobject]@{PackageId=$m.PackageId;Version=$after.Version;AutomaticUninstall=$false;OutputCaptured=$true}}
        }
        Rollback={param($action,$operation,$context) [pscustomobject]@{Status='RollbackRequiresExplicitApproval';RecoveryInformation='WinGet package removal is intentionally not automatic.'}}
    }
}

Export-ModuleMember -Function ConvertTo-InstallVersion,Test-DesiredVersion,New-WinGetProvider,Get-WinGetDiscovery,Get-WinGetPackage,New-WinGetInstallAction,New-WinGetHandler
