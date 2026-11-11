Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Verification.psm1')
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Safety\Backup.psm1')

function New-MigrationAction {
    param([Parameter(Mandatory=$true)][string]$ActionId,[Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Destination,[Parameter(Mandatory=$true)][string]$BackupPath)
    [pscustomobject][ordered]@{ActionId=$ActionId;Component='Storage migration';Description="Migrate $Source to $Destination and preserve source at $BackupPath";ActionType='DIRECTORY_MIGRATE';Risk='High';AffectedPaths=@($Source,$Destination,$BackupPath);Preconditions=@('Source is an ordinary directory or already the correct junction.','Destination is absent or empty.','Application is stopped.','Destination has sufficient free space.');Dependencies=@();ApprovalRequired=$true;SafeToAutomate=$false;RollbackInformation='Restore the preserved source from BackupPath; keep destination data until recovery is verified.';CurrentStatus='PROPOSED';StorageMetadata=[pscustomobject]@{Source=$Source;Destination=$Destination;BackupPath=$BackupPath;SafetyBytes=0}}
}
function Test-MigrationPathRelationship {
    param([string]$Source,[string]$Destination,[string]$BackupPath)
    $failures=@();$paths=@{}
    foreach($pair in @(@{Name='Source';Value=$Source},@{Name='Destination';Value=$Destination},@{Name='Backup';Value=$BackupPath})) {
        try{$paths[$pair.Name]=[IO.Path]::GetFullPath($pair.Value).TrimEnd('\')}catch{$failures+="$($pair.Name) path is invalid."}
    }
    if($paths.ContainsKey('Source') -and $paths.ContainsKey('Destination')) {
        if($paths.Source -ieq $paths.Destination -or $paths.Destination.StartsWith($paths.Source+'\',[StringComparison]::OrdinalIgnoreCase) -or $paths.Source.StartsWith($paths.Destination+'\',[StringComparison]::OrdinalIgnoreCase)){$failures+='Source and destination must be separate, non-nested paths.'}
    }
    foreach($name in @('Source','Destination')) { if($paths.ContainsKey($name) -and $paths.ContainsKey('Backup') -and ($paths.Backup -ieq $paths[$name] -or $paths.Backup.StartsWith($paths[$name]+'\',[StringComparison]::OrdinalIgnoreCase))){$failures+="Backup path must not be inside $name path."} }
    return @($failures)
}
function Get-MigrationSourceBytes { param([string]$Path);$measure=@(Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction Stop | Measure-Object -Property Length -Sum);if(-not $measure.Count -or $null -eq $measure[0].Sum){return [int64]0};return [int64]$measure[0].Sum }
function Test-MigrationPrecondition {
    param($Action,$Context)
    $meta=$Action.StorageMetadata;$source=Get-StoragePathState $meta.Source;$destination=Get-StoragePathState $meta.Destination;$failures=@(Test-MigrationPathRelationship $meta.Source $meta.Destination $meta.BackupPath)
    if($source.Exists -and $source.LinkType -eq 'Junction' -and $source.Target -and $source.Target.TrimEnd('\') -ieq $meta.Destination.TrimEnd('\')){return [pscustomobject]@{Passed=$true;Failures=@();AlreadyMigrated=$true}}
    if(-not $source.Exists){$failures+="Source does not exist: $($meta.Source)"}elseif(-not $source.IsDirectory -or $source.LinkType){$failures+="Source is not an ordinary directory: $($meta.Source)"}
    if($destination.Exists -and (-not $destination.IsDirectory -or $destination.LinkType)){$failures+="Destination is not an ordinary directory: $($meta.Destination)"}
    if($destination.Exists -and @((Get-ChildItem -LiteralPath $meta.Destination -Force -ErrorAction SilentlyContinue)).Count -gt 0){$failures+="Destination is not empty: $($meta.Destination)"}
    if(Test-Path -LiteralPath $meta.BackupPath){$failures+="Backup path already exists: $($meta.BackupPath)"}
    if(-not $Context.PSObject.Properties['ApplicationProbe'] -or -not $Context.ApplicationProbe){$failures+='Application stop probe is required for migration.'}else{try{$running=& $Context.ApplicationProbe $Action $Context;if($running -is [bool] -and $running){$failures+='Application probe reports the application is running.'}elseif($running -and $running.PSObject.Properties['IsRunning'] -and $running.IsRunning){$failures+='Application probe reports the application is running.'}}catch{$failures+='Application stop probe failed.'}}
    if($source.Exists -and $source.IsDirectory -and -not $source.LinkType){$bytes=Get-MigrationSourceBytes $meta.Source;$capacity=Test-DirectoryCapacity $meta.Destination $bytes ([int64]$meta.SafetyBytes);if(-not $capacity.Passed){$failures+=$capacity.Message}}
    [pscustomobject]@{Passed=($failures.Count -eq 0);Failures=@($failures);AlreadyMigrated=$false}
}
function Invoke-SafeRobocopy { param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Destination);$args=@($Source,$Destination,'/E','/COPY:DAT','/DCOPY:DAT','/R:0','/W:0','/XJ','/NFL','/NDL','/NP');& robocopy @args | Out-Null;$exit=$LASTEXITCODE;if($exit -gt 7){throw "Robocopy failed with exit code $exit."};return [pscustomobject]@{ExitCode=$exit;Options=$args} }
function Add-MigrationRecoveryRecord { param($Context,$Record);if($Context.PSObject.Properties['RecoveryRecords'] -and $Context.RecoveryRecords){[void]$Context.RecoveryRecords.Add($Record)} }
function Invoke-TransactionalMigration {
    param([Parameter(Mandatory=$true)]$Action,[Parameter(Mandatory=$true)]$Context)
    $meta=$Action.StorageMetadata;$precondition=Test-MigrationPrecondition $Action $Context;if(-not $precondition.Passed){throw ('Migration preconditions failed: '+($precondition.Failures -join '; '))};if($precondition.AlreadyMigrated){return [pscustomobject]@{Status='AlreadyMigrated';Source=$meta.Source;Destination=$meta.Destination;BackupPath=$meta.BackupPath}}
    $before=Get-DirectorySnapshot $meta.Source;$bytes=Get-MigrationSourceBytes $meta.Source;if(-not (Test-Path -LiteralPath $meta.Destination)){New-Item -ItemType Directory -Path $meta.Destination -Force:$false -ErrorAction Stop | Out-Null}
    try{$copyResult=$null;if($Context.PSObject.Properties['CopyProvider'] -and $Context.CopyProvider){$copyResult=& $Context.CopyProvider $meta.Source $meta.Destination $Context}else{$copyResult=Invoke-SafeRobocopy $meta.Source $meta.Destination};$after=Get-DirectorySnapshot $meta.Destination;$verification=Compare-DirectorySnapshots $before $after;if(-not $verification.Passed){throw ('Copy verification failed: '+($verification.Differences -join '; '))};$manifest=New-BackupManifest $Action (Split-Path -Parent $meta.BackupPath) @($meta.Source);Move-Item -LiteralPath $meta.Source -Destination $meta.BackupPath -Force:$false -ErrorAction Stop;$manifest.Status='Preserved';$manifest.PreservedSource=$meta.BackupPath;New-Item -ItemType Junction -Path $meta.Source -Target $meta.Destination -ErrorAction Stop | Out-Null;$junction=Test-JunctionState $meta.Source $meta.Destination;if(-not $junction.Passed){throw ('Junction verification failed: '+$junction.Message)};[pscustomobject]@{Status='Migrated';Source=$meta.Source;Destination=$meta.Destination;BackupPath=$meta.BackupPath;Bytes=$bytes;Verification=$verification;BackupManifest=$manifest;CopyResult=$copyResult}}
    catch{$record=[pscustomobject]@{ActionId=$Action.ActionId;Source=$meta.Source;Destination=$meta.Destination;BackupPath=$meta.BackupPath;RecoveryRequired=$true;CreatedDestination=(Test-Path -LiteralPath $meta.Destination);PreservedSource=(Test-Path -LiteralPath $meta.BackupPath);ObservedSourceState=(Get-StoragePathState $meta.Source)};Add-MigrationRecoveryRecord $Context $record;throw}
}
function Invoke-MigrationRecovery {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)]$RecoveryRecord)
    if($null -eq $RecoveryRecord){throw 'Recovery record is required.'}
    if(-not $RecoveryRecord.PSObject.Properties['BackupPath'] -or -not (Test-Path -LiteralPath $RecoveryRecord.BackupPath -PathType Container)){throw 'Preserved migration backup is missing.'}
    if(-not $RecoveryRecord.PSObject.Properties['Source'] -or -not $RecoveryRecord.PSObject.Properties['Destination']){throw 'Recovery record lacks source or destination.'}
    $isWhatIf=$false;if($PSBoundParameters.ContainsKey('WhatIf')){$isWhatIf=[bool]$WhatIfPreference}
    $source=Get-StoragePathState $RecoveryRecord.Source
    if($null -eq $source){throw 'Recovery source state could not be determined.'}
    if($source.Exists -and $source.LinkType -eq 'Junction'){
        $actualTarget=[string]$source.Target
        $expectedTarget=[string]$RecoveryRecord.Destination
        if([string]::IsNullOrWhiteSpace($actualTarget) -or $actualTarget.TrimEnd('\') -ine $expectedTarget.TrimEnd('\')){throw 'Recovery source junction target does not match the recorded destination.'}
        if($RecoveryRecord.Source -match '["&|<>^()%!]'){throw 'Recovery source path contains command metacharacters; manual junction removal is required.'}
        if(-not $isWhatIf){& cmd.exe /d /c ('rmdir "{0}"' -f $RecoveryRecord.Source) | Out-Null;if($LASTEXITCODE -ne 0){throw "Could not remove the recorded migration junction: $($RecoveryRecord.Source)"}}
    }
    if(-not (Test-Path -LiteralPath $RecoveryRecord.Source)){if(-not $isWhatIf){Move-Item -LiteralPath $RecoveryRecord.BackupPath -Destination $RecoveryRecord.Source -Force:$false}}
    [pscustomobject]@{Status='Recovered';Source=$RecoveryRecord.Source;Destination=$RecoveryRecord.Destination;BackupPreserved=(Test-Path -LiteralPath $RecoveryRecord.BackupPath)}
}
function New-MigrationRecoveryAction {
    param([Parameter(Mandatory=$true)][string]$ActionId,[Parameter(Mandatory=$true)]$RecoveryRecord)
    [pscustomobject][ordered]@{ActionId=$ActionId;Component='Storage migration recovery';Description="Restore preserved migration source: $($RecoveryRecord.Source)";ActionType='DIRECTORY_RECOVER';Risk='High';AffectedPaths=@($RecoveryRecord.Source,$RecoveryRecord.Destination,$RecoveryRecord.BackupPath);Preconditions=@('Preserved backup exists.','Recorded source junction target is verified before removal.');Dependencies=@();ApprovalRequired=$true;SafeToAutomate=$false;RollbackInformation='Recovery itself is not automatically reversed; preserve the destination and inspect the restored source.';CurrentStatus='PROPOSED';StorageMetadata=[pscustomobject]@{RecoveryRecord=$RecoveryRecord}}
}
function New-MigrationRecoveryHandler {
    $handler=[pscustomobject][ordered]@{TestPrecondition=$null;Execute=$null;Rollback=$null};$handler.TestPrecondition={param($Action,$Context)$record=$Action.StorageMetadata.RecoveryRecord;[pscustomobject]@{Passed=(Test-Path -LiteralPath $record.BackupPath -PathType Container);Failures=@(if(-not (Test-Path -LiteralPath $record.BackupPath -PathType Container)){'Preserved migration backup is missing.'})}}.GetNewClosure();$handler.Execute={param($Action,$Context)Invoke-MigrationRecovery $Action.StorageMetadata.RecoveryRecord}.GetNewClosure();return $handler
}
function New-MigrationHandler {
    $handler=[pscustomobject][ordered]@{TestPrecondition=$null;Execute=$null;Rollback=$null};$handler.TestPrecondition={param($Action,$Context)Test-MigrationPrecondition $Action $Context}.GetNewClosure();$handler.Execute={param($Action,$Context)Invoke-TransactionalMigration $Action $Context}.GetNewClosure();$handler.Rollback={param($Action,$Operation,$Context)if($Context.PSObject.Properties['LastMigrationRecovery'] -and $Context.LastMigrationRecovery){Invoke-MigrationRecovery $Context.LastMigrationRecovery}else{throw 'Migration recovery record is not available.'}}.GetNewClosure();return $handler
}
Export-ModuleMember -Function New-MigrationAction,Test-MigrationPathRelationship,Test-MigrationPrecondition,Invoke-SafeRobocopy,Invoke-TransactionalMigration,Invoke-MigrationRecovery,New-MigrationHandler,New-MigrationRecoveryAction,New-MigrationRecoveryHandler
