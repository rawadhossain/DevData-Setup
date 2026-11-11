# Installation and Fresh-Machine Setup

Release candidate: `0.1.0-rc.1`.

## Prerequisites

- Windows 11 or Windows 10 with supported PowerShell features.
- Windows PowerShell 5.1. Administrator rights only for operations that Windows itself requires.
- Pester 3.4+ for tests. The current validation environment uses Pester 3.4.0.
- Optional providers: WinGet, npm, pnpm, Bun, uv, Go, Docker Desktop, and WSL.
- A reviewed configuration root and sufficient destination capacity.

The repository does not install prerequisites automatically during reconnaissance or audit.

## Setup sequence

```powershell
git clone <repository-url> C:\DevData-bootstrap
Set-Location C:\DevData-bootstrap
Get-ChildItem .\config
```

Review every JSON file. Replace path aliases for the target machine. Keep migration, junction, Docker relocation, WSL migration, and application management disabled until separately reviewed.

Run read-only audit:

```powershell
.\Audit.ps1 -ConfigRoot .\config
```

Review the newest files under `logs\`. Audit does not modify the machine.

Preview bootstrap:

```powershell
.\Bootstrap.ps1 -ConfigPath .\config -ReportPath .\logs -DryRun
```

Review proposed actions, risk, affected paths, preconditions, and reports. Execute only after external approval:

```powershell
.\Bootstrap.ps1 -ConfigPath .\config -ReportPath .\logs -Approve
```

`-Approve` does not bypass preconditions, conflicts, interrupted-operation checks, provider requirements, or verification.

Do not use this release candidate for unattended production migration. Real installations and migrations require a disposable validation machine first.
