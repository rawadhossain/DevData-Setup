Set-StrictMode -Version 2.0

function Get-StoragePathState {
    param([Parameter(Mandatory=$true)][string]$Path)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $exists=$null -ne $item;$linkType=$null;$target=$null
    if($item){$linkType=$item.LinkType;if($item.Target){$target=($item.Target -join ';')}}
    [pscustomobject][ordered]@{Path=$Path;Exists=$exists;IsDirectory=if($item){$item.PSIsContainer}else{$false};Attributes=if($item){$item.Attributes.ToString()}else{$null};LinkType=$linkType;Target=$target;TargetExists=if($target){Test-Path -LiteralPath $target}else{$null}}
}

function Get-StorageFreeBytes {
    param([Parameter(Mandatory=$true)][string]$Path)
    $qualifier=Split-Path -Qualifier $Path;if([string]::IsNullOrWhiteSpace($qualifier) -and $Path -match '^(?<drive>[A-Za-z]):'){ $qualifier=$Matches.drive+':' }
    if([string]::IsNullOrWhiteSpace($qualifier)){return $null}
    try{$drive=New-Object System.IO.DriveInfo(($qualifier.TrimEnd('\')+'\'));return $drive.AvailableFreeSpace}catch{return $null}
}

function Get-DirectorySnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $state=Get-StoragePathState $Path;if(-not $state.Exists -or -not $state.IsDirectory -or $state.LinkType){throw "Snapshot requires an ordinary directory: $Path"}
    $files=@();$directories=@();$root=(Get-Item -LiteralPath $Path -Force).FullName
    $directories+=@('')
    foreach($item in @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop)){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse point found inside snapshot source: $($item.FullName)"}
        $relative=$item.FullName.Substring($root.Length).TrimStart('\')
        if($item.PSIsContainer){$directories+=$relative}else{$hash=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash;$files+=[pscustomobject][ordered]@{RelativePath=$relative;Length=$item.Length;Hash=$hash}}
    }
    [pscustomobject][ordered]@{Root=$root;Files=@($files | Sort-Object RelativePath);Directories=@($directories | Sort-Object);CapturedAt=(Get-Date).ToString('o')}
}

function Compare-DirectorySnapshots {
    param([Parameter(Mandatory=$true)]$Expected,[Parameter(Mandatory=$true)]$Actual)
    $differences=@();$expectedFiles=@($Expected.Files);$actualFiles=@($Actual.Files)
    foreach($file in $expectedFiles){$match=@($actualFiles | Where-Object {$_.RelativePath -eq $file.RelativePath} | Select-Object -First 1);if(-not $match.Count){$differences+="Missing file: $($file.RelativePath)"}elseif($match[0].Length -ne $file.Length -or $match[0].Hash -ne $file.Hash){$differences+="Different file: $($file.RelativePath)"}}
    foreach($file in $actualFiles){if(-not (@($expectedFiles | Where-Object {$_.RelativePath -eq $file.RelativePath}).Count)){$differences+="Unexpected file: $($file.RelativePath)"}}
    return [pscustomobject][ordered]@{Passed=($differences.Count -eq 0);Differences=@($differences);ExpectedFileCount=$expectedFiles.Count;ActualFileCount=$actualFiles.Count}
}

function Test-JunctionState {
    param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Target)
    $state=Get-StoragePathState $Source
    if(-not $state.Exists){return [pscustomobject][ordered]@{Status='Missing';Passed=$false;Source=$Source;ExpectedTarget=$Target;ActualTarget=$null;Message='Source path is missing.'}}
    if($state.LinkType -eq 'SymbolicLink'){return [pscustomobject][ordered]@{Status='WrongLinkType';Passed=$false;Source=$Source;ExpectedTarget=$Target;ActualTarget=$state.Target;Message='Symbolic links are not interchangeable with junctions.'}}
    if($state.LinkType -ne 'Junction'){return [pscustomobject][ordered]@{Status='OrdinaryDirectory';Passed=$false;Source=$Source;ExpectedTarget=$Target;ActualTarget=$null;Message='Source is not a junction.'}}
    if(-not $state.TargetExists){return [pscustomobject][ordered]@{Status='Broken';Passed=$false;Source=$Source;ExpectedTarget=$Target;ActualTarget=$state.Target;Message='Junction target does not exist.'}}
    if($state.Target.TrimEnd('\') -ieq $Target.TrimEnd('\')){return [pscustomobject][ordered]@{Status='Correct';Passed=$true;Source=$Source;ExpectedTarget=$Target;ActualTarget=$state.Target;Message='Junction target is correct.'}}
    [pscustomobject][ordered]@{Status='WrongTarget';Passed=$false;Source=$Source;ExpectedTarget=$Target;ActualTarget=$state.Target;Message='Junction target differs from desired target.'}
}

function Test-DirectoryCapacity {
    param([Parameter(Mandatory=$true)][string]$Destination,[Parameter(Mandatory=$true)][Int64]$RequiredBytes,[Int64]$SafetyBytes=0)
    $free=Get-StorageFreeBytes $Destination;if($null -eq $free){return [pscustomobject][ordered]@{Passed=$false;FreeBytes=$null;RequiredBytes=$RequiredBytes;Message='Destination drive free space could not be determined.'}}
    [pscustomobject][ordered]@{Passed=(($free - $SafetyBytes) -ge $RequiredBytes);FreeBytes=$free;RequiredBytes=$RequiredBytes;SafetyBytes=$SafetyBytes;Message=if(($free-$SafetyBytes) -ge $RequiredBytes){'Sufficient destination capacity.'}else{'Insufficient destination capacity.'}}
}

Export-ModuleMember -Function Get-StoragePathState,Get-StorageFreeBytes,Get-DirectorySnapshot,Compare-DirectorySnapshots,Test-JunctionState,Test-DirectoryCapacity
