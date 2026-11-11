Set-StrictMode -Version 2.0

function Import-JsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
    try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "Invalid JSON in '$Path': $($_.Exception.Message)" }
}

function Import-AuditConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ConfigRoot)
    $names = @('defaults','applications','storage','environment','junctions','versions')
    $config = [ordered]@{}
    foreach($name in $names) { $config[$name] = Import-JsonFile (Join-Path $ConfigRoot ($name + '.json')) }
    return $config
}

function Resolve-AuditValue {
    [CmdletBinding()]
    param([AllowNull()][string]$Value, [Parameter(Mandatory=$true)]$Configuration)
    if($null -eq $Value) { return $null }
    $result = $Value
    $aliases = @{}
    if($Configuration.defaults.PSObject.Properties['paths'] -and $Configuration.defaults.paths) {
        foreach($p in $Configuration.defaults.paths.PSObject.Properties) { $aliases[$p.Name] = [string]$p.Value }
    }
    $aliases['USERPROFILE'] = [Environment]::GetFolderPath('UserProfile')
    $aliases['USERNAME'] = [Environment]::UserName
    foreach($key in $aliases.Keys) { $result = $result.Replace('%' + $key + '%', $aliases[$key]) }
    return [Environment]::ExpandEnvironmentVariables($result)
}

function Resolve-ConfiguredObject {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Object, [Parameter(Mandatory=$true)]$Configuration)
    $copy = [ordered]@{}
    foreach($property in $Object.PSObject.Properties) {
        if($property.Value -is [string]) { $copy[$property.Name] = Resolve-AuditValue $property.Value $Configuration }
        else { $copy[$property.Name] = $property.Value }
    }
    return [pscustomobject]$copy
}

Export-ModuleMember -Function Import-JsonFile,Import-AuditConfiguration,Resolve-AuditValue,Resolve-ConfiguredObject
