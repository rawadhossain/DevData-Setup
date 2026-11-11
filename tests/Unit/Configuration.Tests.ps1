Describe 'DevData Bootstrapper configuration' {
  BeforeAll {
    $configRoot = Join-Path $PSScriptRoot '..\..\config'
  }

  It 'contains parseable JSON configuration files' {
    $files = Get-ChildItem -LiteralPath $configRoot -Filter '*.json' -File
    $files.Count | Should Be 6
    foreach($file in $files) {
      { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } | Should Not Throw
    }
  }

  It 'does not hardcode the observed Windows username in configuration' {
    $content = (Get-ChildItem -LiteralPath $configRoot -Filter '*.json' -File | Get-Content -Raw) -join "`n"
    $content | Should Not Match 'Rawad'
  }

  It 'keeps mutation features disabled in the foundation' {
    $storage = Get-Content (Join-Path $configRoot 'storage.json') -Raw | ConvertFrom-Json
    $junctions = Get-Content (Join-Path $configRoot 'junctions.json') -Raw | ConvertFrom-Json
    $storage.migration.enabled | Should Be $false
    $junctions.enabled | Should Be $false
  }
}
