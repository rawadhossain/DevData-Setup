Set-StrictMode -Version 2.0

function New-BackupManifest {
    param([Parameter(Mandatory=$true)]$Action,[Parameter(Mandatory=$true)][string]$BackupRoot,[string[]]$Paths=@())
    [pscustomobject][ordered]@{ManifestId=('BKP-'+[guid]::NewGuid().ToString('N'));ActionId=$Action.ActionId;BackupRoot=$BackupRoot;Paths=@($Paths);CreatedAt=(Get-Date).ToString('o');Status='Planned';ProviderRequired=$true;PreservedSource=$null;ProviderResult=$null;RestoreResult=$null;RecoveryInformation='A future handler must provide backup and restore providers; no filesystem copy was performed.'}
}
function Invoke-BackupProvider { param([Parameter(Mandatory=$true)]$Manifest,[Parameter(Mandatory=$true)]$Provider,[Parameter(Mandatory=$true)]$Context);if(-not $Provider.PSObject.Properties['Create'] -or -not $Provider.Create){throw 'Backup provider must expose a Create scriptblock.'};$result=& $Provider.Create $Manifest $Context;$Manifest.Status='Completed';$Manifest.ProviderResult=$result;return $Manifest}
function Invoke-RestoreProvider { param([Parameter(Mandatory=$true)]$Manifest,[Parameter(Mandatory=$true)]$Provider,[Parameter(Mandatory=$true)]$Context);if(-not $Provider.PSObject.Properties['Restore'] -or -not $Provider.Restore){throw 'Backup provider must expose a Restore scriptblock.'};$result=& $Provider.Restore $Manifest $Context;$Manifest.Status='Restored';$Manifest.RestoreResult=$result;return $Manifest}
Export-ModuleMember -Function New-BackupManifest,Invoke-BackupProvider,Invoke-RestoreProvider
