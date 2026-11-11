Set-StrictMode -Version 2.0
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\Planner.psm1') -Force

function Test-OfficialSource {
    param([string]$Source)
    try{$uri=New-Object System.Uri($Source);return ($uri.Scheme -eq 'https' -and -not [string]::IsNullOrWhiteSpace($uri.Host))}catch{return $false}
}
function Test-OfficialVersionPolicy {
    param([AllowNull()][string]$Actual,[AllowNull()][string]$Desired,[string]$Policy='Any')
    if([string]::IsNullOrWhiteSpace($Desired) -or $Policy -eq 'Any'){return $true};$a=[regex]::Match([string]$Actual,'(?<!\d)(\d+(?:\.\d+){1,3})(?!\d)');$d=[regex]::Match([string]$Desired,'(?<!\d)(\d+(?:\.\d+){1,3})(?!\d)');if(-not $a.Success -or -not $d.Success){return $false};$av=[version]$a.Groups[1].Value;$dv=[version]$d.Groups[1].Value;if($Policy -eq 'Minimum'){return $av -ge $dv};return $av -eq $dv
}

function New-OfficialInstallerProvider {
    [pscustomobject][ordered]@{
        Download={param($source,$destination)Invoke-WebRequest -Uri $source -OutFile $destination -UseBasicParsing -ErrorAction Stop}
        GetFileHash={param($path)(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
        ExtractZip={param($archive,$destination)if(Test-Path -LiteralPath $destination){$items=@(Get-ChildItem -LiteralPath $destination -Force);if($items.Count){throw 'Destination is not empty.'}};Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force}
        RunInstaller={param($path,$arguments)Start-Process -FilePath $path -ArgumentList $arguments -Wait -PassThru -NoNewWindow}
        Verify={param($executable,$arguments)if(-not (Test-Path -LiteralPath $executable -PathType Leaf)){return $null};$output=& $executable @arguments 2>$null | Select-Object -First 1;[pscustomobject]@{Path=$executable;Version=([string]$output).Trim()}}
    }
}

function New-OfficialInstallerAction {
    param([Parameter(Mandatory=$true)]$Application)
    $install=$Application.installation;$method=[string]$install.method;$type=if($method -eq 'ArchiveZip'){'INSTALL_OFFICIAL_ARCHIVE'}else{'INSTALL_OFFICIAL_EXECUTABLE'};$id='INSTALL-'+[string]$Application.id;$arguments=@();if($install.PSObject.Properties['arguments']){$arguments=@($install.arguments)}
    $dependencies=@();if($Application.PSObject.Properties['dependencies'] -and $Application.dependencies){$dependencies=@($Application.dependencies | ForEach-Object {'INSTALL-'+[string]$_})};$action=New-PlannedAction -ActionId $id -Component ('Installation '+$Application.id) -Description ('Install '+$Application.displayName+' from an official source.') -ActionType $type -Risk 'High' -AffectedPaths @($install.source,$install.destination) -Preconditions @('Source is HTTPS and has expected metadata.','Destination is absent or empty.','Installation approval is explicit.') -Dependencies $dependencies -ApprovalRequired $true -SafeToAutomate $false -RollbackInformation 'Preserve downloaded artifacts and destination state; do not automatically delete or uninstall.'
    Add-Member -InputObject $action -MemberType NoteProperty -Name InstallationMetadata -Value ([pscustomobject][ordered]@{Method=$method;ApplicationId=$Application.id;DisplayName=$Application.displayName;Source=$install.source;Sha256=$install.sha256;Destination=$install.destination;Executable=$install.executable;Arguments=$arguments;Version=if($install.PSObject.Properties['version']){$install.version}else{$null};VersionPolicy=if($install.PSObject.Properties['versionPolicy']){$install.versionPolicy}else{'Any'};Managed=$true})
    return $action
}

function New-OfficialInstallerHandler {
    [pscustomobject][ordered]@{
        TestPrecondition={param($action,$context)
            $m=$action.InstallationMetadata;$failures=@();if(-not (Test-OfficialSource $m.Source)){$failures+='Only HTTPS official sources are accepted.'};if([string]::IsNullOrWhiteSpace($m.Sha256)){$failures+='Expected SHA256 metadata is required.'};if([string]::IsNullOrWhiteSpace($m.Destination)){$failures+='Installation destination is required.'};$executablePath=if($m.Executable -is [string]){[string]$m.Executable}elseif($m.Executable -and $m.Executable.PSObject.Properties['path']){[string]$m.Executable.path}else{$null};if([string]::IsNullOrWhiteSpace($executablePath)){$failures+='Executable verification path is required.'};if($failures.Count){return [pscustomobject]@{Passed=$false;Failures=$failures}};if(Test-Path -LiteralPath $m.Destination){$destinationItem=Get-Item -LiteralPath $m.Destination -Force;if(-not $destinationItem.PSIsContainer){return [pscustomobject]@{Passed=$false;Failures=@('Installation destination is an existing file; overwrite is prohibited.')}};$items=@(Get-ChildItem -LiteralPath $m.Destination -Force -ErrorAction SilentlyContinue);if($items.Count){return [pscustomobject]@{Passed=$false;Failures=@('Installation destination is not empty; overwrite is prohibited.')}}};if(Test-Path -LiteralPath $executablePath -PathType Leaf){return [pscustomobject]@{Passed=$false;Failures=@('Configured executable already exists; overwrite is prohibited.')}};[pscustomobject]@{Passed=$true;Failures=@()}
        }
        Execute={param($action,$context)
            $p=if($context -and $context.PSObject.Properties['OfficialInstallerProvider'] -and $context.OfficialInstallerProvider){$context.OfficialInstallerProvider}else{New-OfficialInstallerProvider};$m=$action.InstallationMetadata;if(-not (Test-OfficialSource $m.Source)){throw 'Official source must use HTTPS.'};$temp=if($context -and $context.PSObject.Properties['TemporaryRoot'] -and $context.TemporaryRoot){Join-Path $context.TemporaryRoot ([guid]::NewGuid().ToString('N'))}else{Join-Path ([IO.Path]::GetTempPath()) ('devdata-install-'+[guid]::NewGuid().ToString('N'))};New-Item -ItemType Directory -Path $temp -Force | Out-Null;$download=Join-Path $temp 'payload';& $p.Download $m.Source $download;& $p.GetFileHash $download | ForEach-Object {if(([string]$_).Trim().ToUpperInvariant() -ne $m.Sha256.Trim().ToUpperInvariant()){throw 'Downloaded file SHA256 does not match configured metadata.'}};if($m.Method -eq 'ArchiveZip'){New-Item -ItemType Directory -Path $m.Destination -Force | Out-Null;& $p.ExtractZip $download $m.Destination}else{& $p.RunInstaller $download $m.Arguments | Out-Null};$executablePath=if($m.Executable -is [string]){[string]$m.Executable}elseif($m.Executable -and $m.Executable.PSObject.Properties['path']){[string]$m.Executable.path}else{$null};$verification=& $p.Verify $executablePath @();if(-not $verification){throw 'Official installer executable verification failed.'};if(-not (Test-OfficialVersionPolicy ([string]$verification.Version) $m.Version $m.VersionPolicy)){throw "Verified executable version '$($verification.Version)' does not satisfy the configured policy."};[pscustomobject]@{Status='Installed';Source=$m.Source;Destination=$m.Destination;Verification=$verification;RecoveryInformation=[pscustomobject]@{TemporaryArtifact=$download;Destination=$m.Destination;AutomaticCleanup=$false;Rollback='Preserve artifacts and use an explicit recovery action.'}}
        }
        Rollback={param($action,$operation,$context) [pscustomobject]@{Status='RollbackRequiresExplicitApproval';RecoveryInformation='Official installer rollback is provider/application-specific and never automatic.'}}
    }
}

Export-ModuleMember -Function Test-OfficialSource,Test-OfficialVersionPolicy,New-OfficialInstallerProvider,New-OfficialInstallerAction,New-OfficialInstallerHandler
