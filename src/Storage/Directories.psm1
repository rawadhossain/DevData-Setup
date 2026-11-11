Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Verification.psm1')

function New-DirectoryCreationAction {
    param([Parameter(Mandatory=$true)][string]$ActionId,[Parameter(Mandatory=$true)][string]$Path)
    [pscustomobject][ordered]@{ActionId=$ActionId;Component='Storage directory';Description="Create directory if missing: $Path";ActionType='DIRECTORY_CREATE';Risk='Medium';AffectedPaths=@($Path);Preconditions=@('Destination path is absent or an ordinary directory.');Dependencies=@();ApprovalRequired=$true;SafeToAutomate=$false;RollbackInformation='Remove only the newly created empty directory after verification.';CurrentStatus='PROPOSED';StorageMetadata=[pscustomobject]@{Path=$Path}}
}
function New-DirectoryHandler {
    $handler=[pscustomobject][ordered]@{TestPrecondition=$null;Execute=$null;Rollback=$null}
    $handler.TestPrecondition={param($Action,$Context)$path=$Action.StorageMetadata.Path;$state=Get-StoragePathState $path;if(-not $state.Exists -or ($state.IsDirectory -and -not $state.LinkType)){return [pscustomobject]@{Passed=$true;Failures=@()}};[pscustomobject]@{Passed=$false;Failures=@("Destination exists and is not an ordinary directory: $path")}}.GetNewClosure()
    $handler.Execute={param($Action,$Context)$path=$Action.StorageMetadata.Path;$state=Get-StoragePathState $path;if($state.Exists){return [pscustomobject]@{Status='AlreadyExists';Path=$path;Created=$false}};New-Item -ItemType Directory -Path $path -Force:$false -ErrorAction Stop | Out-Null;[pscustomobject]@{Status='Created';Path=$path;Created=$true}}.GetNewClosure()
    $handler.Rollback={param($Action,$Operation,$Context)$path=$Action.StorageMetadata.Path;$state=Get-StoragePathState $path;if($state.Exists -and $state.IsDirectory -and -not $state.LinkType -and -not @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop).Count){Remove-Item -LiteralPath $path -Force -Confirm:$false -ErrorAction Stop;return [pscustomobject]@{Status='RemovedEmptyCreatedDirectory';Path=$path}};[pscustomobject]@{Status='ManualRecoveryRequired';Path=$path}}.GetNewClosure()
    return $handler
}
Export-ModuleMember -Function New-DirectoryCreationAction,New-DirectoryHandler
