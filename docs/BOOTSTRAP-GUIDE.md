# Bootstrap Guide

Bootstrap combines discovery, comparison, planning, conflict checks, Executor approval, verification, and reporting.

## Parameters

- `-ConfigPath`: configuration directory. Default: `.\config`.
- `-ReportPath`: report directory. Default: `.\logs`.
- `-Component`: limit planning to matching component names.
- `-DryRun`: write journal preview records; never invoke handlers.
- `-WhatIf`: PowerShell preview mode; never invoke handlers.
- `-Approve`: approve planned actions after all checks pass.

## Examples

```powershell
.\Bootstrap.ps1 -ConfigPath .\config -DryRun
.\Bootstrap.ps1 -ConfigPath .\config -Component 'PackageManager' -DryRun
.\Bootstrap.ps1 -ConfigPath .\config -WhatIf
.\Bootstrap.ps1 -ConfigPath .\config -Approve
```

Exit codes:

- `0`: success or dry-run.
- `1`: execution or verification failure.
- `2`: explicit approval required.
- `3`: conflicting plan.

The default configuration does not manage installations, junctions, ordinary migrations, Docker relocation, or WSL migration. Enabling those features requires provider support, preconditions, approval, backups where applicable, and verification.

The operation journal and JSONL log preserve action status. Do not delete them until recovery review is complete.
