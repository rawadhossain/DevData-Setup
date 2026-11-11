Set-StrictMode -Version 2.0

function New-PackageManagerCommandProvider {
    [pscustomobject][ordered]@{
        GetCommand={param($name) Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1}
        Invoke={param($command,$arguments) & $command.Source @arguments 2>&1 | Out-String | ForEach-Object {$_.Trim()}}
        Set={param($manager,$setting,$value)
            $command=Get-Command $manager -ErrorAction Stop
            if($manager -eq 'npm'){& $command.Source 'config' 'set' $setting $value}
            elseif($manager -eq 'pnpm'){& $command.Source 'config' 'set' $setting $value}
            else{throw "Native configuration for '$manager' is not implemented."}
        }
    }
}

function Get-PackageManagerConfiguration {
    param($Provider)
    if(-not $Provider){$Provider=New-PackageManagerCommandProvider}
    $result=[ordered]@{}
    foreach($manager in @('npm','pnpm','bun','uv','go')){
        $command=& $Provider.GetCommand $manager
        $state=[ordered]@{Manager=$manager;Available=($null -ne $command);CommandPath=if($command){$command.Source}else{$null};Version=$null;Settings=[ordered]@{}}
        if($command){$state.Version=(& $Provider.Invoke $command @('--version'))}
        if($manager -eq 'npm' -and $command){foreach($setting in @('prefix','cache','userconfig')){$state.Settings[$setting]=(& $Provider.Invoke $command @('config','get',$setting))}}
        if($manager -eq 'pnpm' -and $command){foreach($setting in @('store-dir','global-dir','global-bin-dir')){$state.Settings[$setting]=(& $Provider.Invoke $command @('config','get',$setting))}}
        if($manager -eq 'uv' -and $command){$state.Settings['cache-dir']=(& $Provider.Invoke $command @('cache','dir'));$state.Settings['python-dir']=(& $Provider.Invoke $command @('python','dir'))}
        if($manager -eq 'uv' -and $command){$state.Settings['managed-python']=(& $Provider.Invoke $command @('python','find'))}
        if($manager -eq 'uv'){foreach($setting in @('UV_CACHE_DIR','UV_PYTHON_INSTALL_DIR','UV_PYTHON_BIN_DIR','UV_TOOL_DIR','UV_TOOL_BIN_DIR','PIP_CACHE_DIR')){$state.Settings[$setting]=[Environment]::GetEnvironmentVariable($setting,'User')}}
        if($manager -eq 'bun' -and $command){$bunInstall=[Environment]::GetEnvironmentVariable('BUN_INSTALL','User');$state.Settings['BUN_INSTALL']=$bunInstall;$state.Settings['executable-dir']=if($bunInstall){Join-Path $bunInstall 'bin'}else{$null};$state.Settings['cache-dir']=[Environment]::GetEnvironmentVariable('BUN_INSTALL_CACHE_DIR','User')}
        if($manager -eq 'go' -and $command){foreach($setting in @('GOROOT','GOPATH','GOCACHE','GOMODCACHE','GOBIN')){$state.Settings[$setting]=(& $Provider.Invoke $command @('env',$setting))}}
        $result[$manager]=[pscustomobject]$state
    }
    return [pscustomobject]$result
}

function Compare-PackageManagerConfiguration {
    param([Parameter(Mandatory=$true)]$Expected,[Parameter(Mandatory=$true)]$Actual)
    $findings=@()
    foreach($managerProperty in $Expected.PSObject.Properties){$manager=$managerProperty.Name;$expectedSettings=$managerProperty.Value;if(-not $Actual.PSObject.Properties[$manager]){continue};$actualManager=$Actual.$manager
        foreach($settingProperty in $expectedSettings.PSObject.Properties){$expectedValue=$settingProperty.Value;if($null -eq $expectedValue -or [string]::IsNullOrWhiteSpace([string]$expectedValue)){continue};$actualValue=$null;$hasActual=$false;if($actualManager.Settings -is [System.Collections.IDictionary]){$hasActual=$actualManager.Settings.Contains($settingProperty.Name);if($hasActual){$actualValue=$actualManager.Settings[$settingProperty.Name]}}elseif($actualManager.Settings.PSObject.Properties[$settingProperty.Name]){$hasActual=$true;$actualValue=$actualManager.Settings.PSObject.Properties[$settingProperty.Name].Value};$status=if(-not $actualManager.Available){'MISSING'}elseif(-not $hasActual -or $null -eq $actualValue){'UNKNOWN'}elseif([string]$actualValue -eq [string]$expectedValue){'PASS'}else{'MISMATCH'};$expectedState=[ordered]@{};$expectedState[$settingProperty.Name]=$expectedValue;$actualState=[ordered]@{};$actualState[$settingProperty.Name]=$actualValue;$findings+=[pscustomobject][ordered]@{Component="PackageManager/$manager";ExpectedState=[pscustomobject]$expectedState;ActualState=[pscustomobject]$actualState;Status=$status;RecommendedAction=if($status -in @('MISMATCH','UNKNOWN')){'Inspect and, if confirmed, plan an approved native configuration update.'}else{$null};SafeToAutomate=($status -eq 'MISMATCH')}}
    }
    return $findings
}

function New-PackageManagerConfigurationAction {
    param([Parameter(Mandatory=$true)][string]$ActionId,[Parameter(Mandatory=$true)][ValidateSet('npm','pnpm')][string]$Manager,[Parameter(Mandatory=$true)][string]$Setting,[Parameter(Mandatory=$true)][string]$DesiredValue)
    [pscustomobject][ordered]@{ActionId=$ActionId;Component="PackageManager/$Manager";Description="Configure $Manager $Setting";ActionType='PACKAGE_MANAGER_CONFIGURE';Risk='High';AffectedPaths=@($DesiredValue);Preconditions=@('Package manager command is available');Dependencies=@();ApprovalRequired=$true;SafeToAutomate=$false;RollbackInformation='Restore the previous package-manager setting.';CurrentStatus='PLANNED';PackageManagerMetadata=[pscustomobject][ordered]@{Manager=$Manager;Setting=$Setting;DesiredValue=$DesiredValue;Managed=$true}}
}

function New-PackageManagerHandler {
    [pscustomobject][ordered]@{
        TestPrecondition={param($action,$context)
            $p=if($context -and $context.PSObject.Properties['PackageManagerProvider'] -and $context.PackageManagerProvider){$context.PackageManagerProvider}else{New-PackageManagerCommandProvider};$c=& $p.GetCommand $action.PackageManagerMetadata.Manager
            if(-not $c){return [pscustomobject]@{Passed=$false;Failures=@("Command '$($action.PackageManagerMetadata.Manager)' is unavailable.")}};return [pscustomobject]@{Passed=$true;Failures=@()}
        }
        Execute={param($action,$context)
            $m=$action.PackageManagerMetadata;$p=if($context -and $context.PSObject.Properties['PackageManagerProvider'] -and $context.PackageManagerProvider){$context.PackageManagerProvider}else{New-PackageManagerCommandProvider};$state=Get-PackageManagerConfiguration $p;$current=$state.($m.Manager).Settings[$m.Setting]
            if([string]$current -eq [string]$m.DesiredValue){return [pscustomobject]@{Status='AlreadyCorrect';RecoveryInformation='No change required.'}}
            & $p.Set $m.Manager $m.Setting $m.DesiredValue | Out-Null;$after=(Get-PackageManagerConfiguration $p).($m.Manager).Settings[$m.Setting];if([string]$after -ne [string]$m.DesiredValue){throw "Package-manager setting '$($m.Manager)/$($m.Setting)' did not verify."}
            [pscustomobject]@{Status='Updated';RecoveryInformation=[pscustomobject]@{Manager=$m.Manager;Setting=$m.Setting;PreviousValue=$current;RestoreAction='Set the previous native package-manager value.'}}
        }
    }
}

Export-ModuleMember -Function New-PackageManagerCommandProvider,Get-PackageManagerConfiguration,Compare-PackageManagerConfiguration,New-PackageManagerConfigurationAction,New-PackageManagerHandler
