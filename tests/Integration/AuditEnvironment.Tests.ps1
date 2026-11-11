$core=Join-Path $PSScriptRoot '..\..\src\Core'
Import-Module (Join-Path $core 'Configuration.psm1') -Force
Import-Module (Join-Path $core 'Discovery.psm1') -Force
Import-Module (Join-Path $core 'Comparison.psm1') -Force
Import-Module (Join-Path $core 'Planner.psm1') -Force
Import-Module (Join-Path $core 'Reporting.psm1') -Force

Describe 'Environment audit integration' {
  It 'compares package managers, Go, environment, duplicate and malformed PATH entries' {
    $config=Import-AuditConfiguration (Join-Path $PSScriptRoot '..\..\config')
    $discovery=[pscustomobject][ordered]@{
      Windows=[pscustomobject]@{OperatingSystem='Windows'};DeveloperDirectories=@();InstalledSoftware=@();Tools=@()
      Environment=[pscustomobject]@{User=[pscustomobject]@{GOBIN='D:\DevData\Go\bin';EXAMPLE_TOKEN='hidden'};Machine=[pscustomobject]@{};Process=[pscustomobject]@{}}
      Path=[pscustomobject]@{User=[pscustomobject]@{Entries=@('D:\Node','D:\Node','D:\Go\bin D:\GoSDK\bin');Duplicates=@([pscustomobject]@{Normalized='d:\node';Entries=@('D:\Node','D:\Node')});MalformedCandidates=@('D:\Go\bin D:\GoSDK\bin')};Machine=[pscustomobject]@{Entries=@('D:\Node');Duplicates=@();MalformedCandidates=@()};CrossScopeDuplicates=@([pscustomobject]@{Normalized='d:\node';Entries=@([pscustomobject]@{Scope='User';Entry='D:\Node'},[pscustomobject]@{Scope='Machine';Entry='D:\Node'})})}
      PackageManagers=[pscustomobject]@{ConfigurationPaths=[ordered]@{'npm.prefix'='D:\wrong';'npm.cache'='D:\DevData\PackageManagers\npm-cache';'pnpm.store-dir'='D:\DevData\PackageManagers\pnpm-store';'bun.BUN_INSTALL'='D:\DevData\PackageManagers\.bun';'uv.cache-dir'='D:\DevData\Python\uv-cache';'uv.python-dir'='D:\DevData\Python\uv-python'}}
      PythonUv=[pscustomobject]@{UserSite=(Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Roaming\Python\Python313\site-packages');Prefix='D:\DevData\Python\uv-python';PythonPath='D:\DevData\Python\uv-python\python.exe';Version='3.13.0'}
      Go=[pscustomobject]@{Environment=[ordered]@{GOROOT='D:\DevData\GoSDK\go';GOPATH='D:\DevData\Go';GOMODCACHE='D:\DevData\Go\pkg\mod';GOCACHE='D:\DevData\Go\cache';GOBIN='D:\DevData\Go\bin'};Version='go1.25.0';Path='D:\go.exe'}
      Drives=@();DockerWsl=[pscustomobject]@{Registrations=@()}
    }
    $findings=@(Compare-AuditState $config $discovery)
    @($findings | Where-Object {$_.Component -eq 'Package manager npm.prefix' -and $_.Status -eq 'MISMATCH'}).Count | Should Be 1
    @($findings | Where-Object {$_.Component -eq 'Package manager npm.cache' -and $_.Status -eq 'PASS'}).Count | Should Be 1
    @($findings | Where-Object {$_.Component -eq 'PATH user duplicate' -and $_.Status -eq 'MISMATCH'}).Count | Should Be 1
    @($findings | Where-Object {$_.Component -eq 'PATH user malformed entry' -and $_.Status -eq 'MISMATCH'}).Count | Should Be 1
    @($findings | Where-Object {$_.Component -eq 'Python user-site' -and $_.Status -eq 'WARNING'}).Count | Should Be 1
  }

  It 'redacts sensitive environment values in both JSON and Markdown report output' {
    $root=Join-Path $env:TEMP ('devdata-audit-report-'+[guid]::NewGuid().ToString());New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
      $report=ConvertTo-SafeReportObject ([pscustomobject]@{}) ([pscustomobject]@{Windows=[pscustomobject]@{};Environment=[pscustomobject]@{User=[pscustomobject]@{API_TOKEN='super-secret-token'}}}) @() @() (Get-Date).ToString('o')
      $written=Write-AuditReports $report $root;$json=Get-Content $written.JsonPath -Raw;$markdown=Get-Content $written.MarkdownPath -Raw
      $json | Should Not Match 'super-secret-token';$markdown | Should Not Match 'super-secret-token';$json | Should Match '\[REDACTED\]'
    } finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
  }
}
