# Repair and Recovery Guide

Repair re-audits state, reads the operation journal, plans drift repair, classifies incomplete operations, and writes reports.

```powershell
.\Repair.ps1 -ConfigPath .\config -ReportPath .\logs -DryRun
.\Repair.ps1 -ConfigPath .\config -Component 'Junction' -DryRun
.\Repair.ps1 -ConfigPath .\config -OperationId <operation-id> -DryRun
.\Repair.ps1 -ConfigPath .\config -OperationId <operation-id> -Approve
```

Repair exit code `4` means manual recovery remains required. Other codes match Bootstrap, except that `3` still means plan conflict.

Interrupted operations are never blindly retried. Pending, running, and failed operations are classified from journal state. Most migration, installation, PATH, environment, application, Docker, and WSL recovery remains manual because the current journal does not persist enough provider-specific mutation state.

Completed junction creation may receive a targeted rollback action. The handler validates the current link type and target before removal. It does not remove unknown directories or targets.

For manual recovery:

1. Stop the affected application, Docker Desktop, or WSL distribution.
2. Preserve original paths, destinations, backups, and export archives.
3. Inspect the operation record and affected paths.
4. Use provider-specific recovery instructions.
5. Re-run audit after recovery.

Never delete backups automatically. Do not directly manipulate active Docker or WSL VHDX files.
