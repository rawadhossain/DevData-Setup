Set-StrictMode -Version 2.0

function Protect-LogString {
    param([AllowNull()][string]$Value)
    if($null -eq $Value){return $null}
    $safe=$Value -replace '(?i)(bearer\s+)[^\s;]+','$1[REDACTED]'
    $safe=$safe -replace '(?i)((?:token|secret|password|passwd|api[_-]?key|access[_-]?key)\s*[:=]\s*)[^\s,;]+','$1[REDACTED]'
    return $safe
}

function ConvertTo-SafeLogValue {
    param($Value,[string]$PropertyName='')
    if($PropertyName -match '(?i)token|secret|password|passwd|credential|auth|private.?key|ssh|api.?key|access.?key'){return '[REDACTED]'}
    if($null -eq $Value){return $null}
    if($Value -is [string]){return Protect-LogString ([string]$Value)}
    if($Value -is [System.Collections.IDictionary]){$out=[ordered]@{};foreach($key in $Value.Keys){$out[$key]=ConvertTo-SafeLogValue $Value[$key] ([string]$key)};return [pscustomobject]$out}
    if($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])){$items=@();foreach($item in $Value){$items+=ConvertTo-SafeLogValue $item $PropertyName};return $items}
    if(@($Value.PSObject.Properties).Count -gt 0 -and -not ($Value -is [ValueType])){$out=[ordered]@{};foreach($property in $Value.PSObject.Properties){$out[$property.Name]=ConvertTo-SafeLogValue $property.Value $property.Name};return [pscustomobject]$out}
    return $Value
}

function Get-SanitizedError {
    param([AllowNull()]$Error)
    if($null -eq $Error){return $null}
    $message=if($Error -is [System.Management.Automation.ErrorRecord]){$Error.Exception.Message}else{[string]$Error}
    [pscustomobject][ordered]@{Type=if($Error.Exception){$Error.Exception.GetType().FullName}else{$Error.GetType().FullName};Message=(Protect-LogString $message)}
}

function New-StructuredLogger {
    param([Parameter(Mandatory=$true)][string]$Path)
    [pscustomobject][ordered]@{Path=$Path}
}

function Write-StructuredLog {
    param([Parameter(Mandatory=$true)]$Logger,[ValidateSet('Debug','Information','Warning','Error')][string]$Level='Information',[Parameter(Mandatory=$true)][string]$Message,[string]$ActionId,[string]$Component,[AllowNull()]$Data,[AllowNull()]$Error)
    $parent=Split-Path -Parent $Logger.Path;if($parent -and -not (Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force | Out-Null}
    $entry=[pscustomobject][ordered]@{Timestamp=(Get-Date).ToString('o');Level=$Level;ActionId=$ActionId;Component=$Component;Message=(Protect-LogString $Message);Data=(ConvertTo-SafeLogValue $Data);Error=Get-SanitizedError $Error}
    $entry | ConvertTo-Json -Depth 12 -Compress | Out-File -LiteralPath $Logger.Path -Append -Encoding UTF8
}

Export-ModuleMember -Function New-StructuredLogger,Write-StructuredLog,Get-SanitizedError,Protect-LogString,ConvertTo-SafeLogValue
