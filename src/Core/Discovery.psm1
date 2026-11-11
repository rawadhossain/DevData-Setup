Set-StrictMode -Version 2.0
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Environment\Variables.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Environment\Path.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Environment\PackageManagers.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Infrastructure\DockerWsl.psm1')

function Get-SafeCommand {
    param([string]$Name)
    return (Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Invoke-SafeVersionCommand {
    param([string]$Name, [string[]]$Arguments = @('--version'))
    $command = Get-SafeCommand $Name
    if(-not $command) { return $null }
    try { return ((& $command.Source @Arguments 2>&1 | Select-Object -First 1 | Out-String).Trim()) }
    catch { return $null }
}

function Get-WindowsAndPowerShellDiscovery {
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
    $edition = $null
    try { $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop) } catch {}
    [pscustomobject][ordered]@{
        ComputerName = $env:COMPUTERNAME
        OperatingSystem = if($os){$os.Caption}else{$null}
        OperatingSystemVersion = if($os){$os.Version}else{$null}
        BuildNumber = if($os){$os.BuildNumber}elseif($edition){$edition.CurrentBuild}else{$null}
        Edition = if($edition){$edition.ProductName}else{$null}
        Architecture = $env:PROCESSOR_ARCHITECTURE
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        PowerShellEdition = $PSVersionTable.PSEdition
    }
}

function Get-DriveDiscovery {
    $result = @()
    foreach($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $free = $null; $total = $null
        try { $info = New-Object System.IO.DriveInfo($drive.Root); $free=$info.AvailableFreeSpace; $total=$info.TotalSize } catch {}
        $result += [pscustomobject][ordered]@{ Name=$drive.Name; Root=$drive.Root; Provider=$drive.Provider.Name; FreeBytes=$free; TotalBytes=$total; FreeGB=if($free -ne $null){[math]::Round($free/1GB,2)}else{$null}; Exists=$true }
    }
    return $result
}

function Get-PathMetadata {
    param([string]$Path)
    $exists = Test-Path -LiteralPath $Path
    $item = $null; $target = $null; $linkType = $null
    if($exists) { $item=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue; if($item){$target=if($item.Target){$item.Target -join ';'}else{$null};$linkType=$item.LinkType} }
    [pscustomobject][ordered]@{ Path=$Path; Exists=$exists; IsDirectory=if($item){$item.PSIsContainer}else{$false}; Attributes=if($item){$item.Attributes.ToString()}else{$null}; LinkType=$linkType; Target=$target }
}

function Get-DeveloperDirectoryDiscovery {
    param([Parameter(Mandatory=$true)]$Configuration)
    $paths = @([Environment]::GetFolderPath('UserProfile'), [Environment]::GetFolderPath('LocalApplicationData'), [Environment]::GetFolderPath('ApplicationData'))
    foreach($property in $Configuration.storage.roots.PSObject.Properties) { $paths += (Resolve-AuditValue ([string]$property.Value) $Configuration) }
    foreach($junction in $Configuration.junctions.junctions) { $paths += (Resolve-AuditValue ([string]$junction.source) $Configuration) }
    $paths = $paths | Where-Object { $_ } | Select-Object -Unique
    return @($paths | ForEach-Object { Get-PathMetadata $_ })
}

function Get-InstalledSoftwareDiscovery {
    $roots=@('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')
    return @(Get-ItemProperty $roots -ErrorAction SilentlyContinue | Where-Object {$_.PSObject.Properties['DisplayName'] -and $_.DisplayName} | Select-Object DisplayName,DisplayVersion,Publisher,InstallLocation,PSPath | Sort-Object DisplayName,DisplayVersion -Unique)
}

function Test-SensitiveName { param([string]$Name); return ($Name -match '(?i)token|secret|password|passwd|credential|auth|private.?key|ssh|key') }
function ConvertTo-SafeEnvironmentValue {
    param([string]$Name,[AllowNull()][string]$Value)
    if(Test-SensitiveName $Name){ return '[REDACTED]' }
    return $Value
}
function Get-EnvironmentDiscovery {
    $read = { param($scope) $out=[ordered]@{}; $snapshot=Get-EnvironmentScopeSnapshot $scope; foreach($property in $snapshot.PSObject.Properties){$out[$property.Name]=ConvertTo-SafeEnvironmentValue $property.Name ([string]$property.Value.Value)}; return $out }
    [pscustomobject][ordered]@{ User=& $read 'User'; Machine=& $read 'Machine'; Process=& $read 'Process' }
}

function Get-PathDiscovery {
    param($Provider)
    if(-not $Provider){$Provider=New-PathProvider}
    $scopes=[ordered]@{ User=(& $Provider.Get 'User'); Machine=(& $Provider.Get 'Machine'); Process=(& $Provider.Get 'Process') }
    $scopeResults=[ordered]@{}
    foreach($scope in $scopes.Keys) {
        $inspection=Get-PathInspection $scope ([string]$scopes[$scope]);$entries=@($inspection.Entries | ForEach-Object {$_.Original});$duplicates=@($inspection.Duplicates | ForEach-Object {[pscustomobject]@{Normalized=$_.Normalized;Entries=@($_.Entries | ForEach-Object {$_.Original})}});$malformed=@($inspection.MalformedCandidates | ForEach-Object {$_.Original})
        $scopeResults[$scope]=[pscustomobject][ordered]@{Entries=$entries;Count=$entries.Count;Duplicates=$duplicates;MalformedCandidates=$malformed;RawPresent=($null -ne $scopes[$scope])}
    }
    $cross=@{}; foreach($scope in @('User','Machine')){foreach($entry in @($scopeResults[$scope].Entries)){$key=$entry.ToLowerInvariant();if(-not $cross.ContainsKey($key)){$cross[$key]=@()};$cross[$key]+=[pscustomobject]@{Scope=$scope;Entry=$entry}}}
    $crossDuplicates=@($cross.GetEnumerator() | Where-Object {(@($_.Value | Select-Object -ExpandProperty Scope -Unique)).Count -gt 1} | ForEach-Object {[pscustomobject]@{Normalized=$_.Key;Entries=@($_.Value)}})
    [pscustomobject][ordered]@{User=$scopeResults.User;Machine=$scopeResults.Machine;Process=$scopeResults.Process;CrossScopeDuplicates=$crossDuplicates}
}

function Get-PackageManagerDiscovery {
    param($Provider)
    $state=Get-PackageManagerConfiguration $Provider; $commands=@();$values=[ordered]@{}
    foreach($property in $state.PSObject.Properties){$manager=$property.Name;$item=$property.Value;$commands+=[pscustomobject]@{Name=$manager;Path=$item.CommandPath;Version=$item.Version;Available=$item.Available};foreach($setting in $item.Settings.Keys){$values[($manager+'.'+$setting)]=[string]$item.Settings[$setting]}}
    [pscustomobject][ordered]@{Commands=$commands;ConfigurationPaths=$values;Managers=$state}
}

function Get-PythonUvDiscovery {
    $python=Get-SafeCommand python; $py=Get-SafeCommand py; $uv=Get-SafeCommand uv
    $data=[ordered]@{PythonPath=if($python){$python.Source}else{$null};Version=Invoke-SafeVersionCommand python;UserSite=$null;Prefix=$null;PyLauncher=if($py){$py.Source}else{$null};UvPath=if($uv){$uv.Source}else{$null}}
    if($python){try{$lines=& $python.Source -c "import sys,site; print(sys.prefix); print(site.getusersitepackages())" 2>$null; if($lines.Count -ge 2){$data.Prefix=$lines[0];$data.UserSite=$lines[1]}}catch{}}
    return [pscustomobject]$data
}

function Get-GoDiscovery {
    $go=Get-SafeCommand go; $envData=[ordered]@{}
    if($go){foreach($key in @('GOROOT','GOPATH','GOMODCACHE','GOCACHE','GOENV','GOBIN','GOTOOLCHAIN')){$envData[$key]=((& $go.Source env $key 2>$null | Select-Object -First 1 | Out-String).Trim())}}
    [pscustomobject][ordered]@{Path=if($go){$go.Source}else{$null};Version=if($go){((& $go.Source version 2>$null | Select-Object -First 1 | Out-String).Trim())}else{$null};Environment=$envData}
}

function Get-ToolDiscovery {
    $probes=@(
        @{Name='git';Command='git'}, @{Name='vscode';Command='code'}, @{Name='node';Command='node'},
        @{Name='docker-desktop';Command='docker'}, @{Name='wsl';Command='wsl'}
    )
    $result=@()
    foreach($probe in $probes){$command=Get-SafeCommand $probe.Command;$result += [pscustomobject][ordered]@{Name=$probe.Name;Command=$probe.Command;Path=if($command){$command.Source}else{$null};Version=if($command){Invoke-SafeVersionCommand $probe.Command}else{$null}}}
    return $result
}

function Get-DockerWslDiscovery {
    return (Get-DockerWslInfrastructureDiscovery $null $null)
}

function Get-MachineDiscovery {
    param([Parameter(Mandatory=$true)]$Configuration,[hashtable]$Providers=@{})
    [pscustomobject][ordered]@{
        Windows=Get-WindowsAndPowerShellDiscovery
        Drives=Get-DriveDiscovery
        DeveloperDirectories=Get-DeveloperDirectoryDiscovery $Configuration
        InstalledSoftware=Get-InstalledSoftwareDiscovery
        Tools=Get-ToolDiscovery
        Environment=Get-EnvironmentDiscovery
        Path=if($Providers.ContainsKey('Path')){Get-PathDiscovery $Providers.Path}else{Get-PathDiscovery}
        PackageManagers=if($Providers.ContainsKey('PackageManagers')){Get-PackageManagerDiscovery $Providers.PackageManagers}else{Get-PackageManagerDiscovery}
        PythonUv=Get-PythonUvDiscovery
        Go=Get-GoDiscovery
        DockerWsl=if($Providers.ContainsKey('DockerWsl')){Get-DockerWslInfrastructureDiscovery $Configuration $Providers.DockerWsl}else{Get-DockerWslInfrastructureDiscovery $Configuration}
    }
}

Export-ModuleMember -Function Get-MachineDiscovery,Get-PathMetadata,Get-PathDiscovery,Get-DriveDiscovery,Get-EnvironmentDiscovery,ConvertTo-SafeEnvironmentValue,Get-ToolDiscovery,Get-PackageManagerDiscovery,Get-PythonUvDiscovery,Get-GoDiscovery,Get-DockerWslDiscovery
