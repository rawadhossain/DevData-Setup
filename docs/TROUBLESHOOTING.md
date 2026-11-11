# Troubleshooting

## Configuration file not found or invalid JSON

Run:

```powershell
Get-ChildItem .\config\*.json
Get-Content .\config\defaults.json -Raw | ConvertFrom-Json
```

Keep all six required JSON files present.

## Approval required

Review the plan and rerun with `-Approve` only after confirming affected paths. Approval cannot bypass failed preconditions.

## Plan conflict

Use the report's affected paths and component names. Disable one conflicting component or correct configuration ownership. Do not force execution.

## Interrupted operation

Run Repair with `-DryRun`. Use the reported `OperationId`. Automatic recovery is intentionally limited. Preserve all backups and inspect the original operation before retrying.

## Missing provider or executable

Audit reports unavailable WinGet, Docker, WSL, npm, pnpm, Bun, uv, or Go as missing or unknown. Install or enable the provider separately, then rerun audit. The bootstrapper does not silently substitute providers.

## Insufficient capacity

Free space is checked before migration, export, or import planning where provider data permits. Choose another configured destination. Do not delete backups to make space.

## PATH mismatch

Review scope, duplicates, and malformed entries. Unmanaged entries preserve order. Ambiguous duplicates and malformed Go entries are not automatically removed.

## No report written

Check that `-ReportPath` exists or is creatable and that the process has write access. Report paths must not point at credential directories.
