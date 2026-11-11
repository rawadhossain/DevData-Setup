# DevData Bootstrapper

Version: `0.1.0-rc.1` — experimental release candidate. Do not use for unattended production changes.

DevData Bootstrapper is a configuration-driven Windows PowerShell 5.1 automation system for building and maintaining a developer workstation.

It is intended to:

- discover installed developer tools and relevant data locations;
- plan safe, repeatable changes from JSON configuration;
- install missing tools in a later milestone;
- migrate application data and caches to a configurable developer-data drive;
- configure environment variables, PATH, Python, Node.js, Go, Docker, and WSL;
- create and validate directory junctions;
- audit drift and repair approved mismatches; and
- verify operations while preserving backups and structured logs.

## Current status

This repository contains the project foundation, machine baseline, read-only audit engine, execution safety foundation, storage handlers, environment/PATH/package-manager handlers, provider-based software installation, application adapters, Docker/WSL infrastructure, and end-to-end bootstrap orchestration. Mutations remain approval-gated and provider-specific; tests use mocks and do not modify the machine.

Start with:

- [Machine baseline](docs/MACHINE-BASELINE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Implementation plan](docs/IMPLEMENTATION-PLAN.md)
- [Configuration reference](docs/CONFIGURATION.md)
- [Fresh-machine setup](docs/INSTALLATION.md)
- [Audit guide](docs/AUDIT-GUIDE.md)
- [Bootstrap guide](docs/BOOTSTRAP-GUIDE.md)
- [Repair and recovery](docs/REPAIR-RECOVERY.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Release checklist](docs/RELEASE-CHECKLIST.md)

## Requirements

Supported target: Windows 10/11 with Windows PowerShell 5.1. Optional providers are WinGet, npm, pnpm, Bun, uv, Go, Docker Desktop, and WSL. Pester is required only for test execution.

Repository structure: entrypoint scripts are at the root; JSON desired state is under `config\`; reusable PowerShell modules are under `src\`; tests are under `tests\`; documentation is under `docs\`; ignored runtime logs and backups are under `logs\` and `backups\`.

## Safety principles

All execution entry points will support dry-run planning. Destructive operations require explicit approval, must preserve recovery data, and must verify their postconditions. Configuration is generic: it must never hardcode a Windows username or assume a particular drive letter without an explicit setting.

## Bootstrap usage

```powershell
.\Audit.ps1 -ConfigRoot .\config
.\Bootstrap.ps1 -ConfigPath .\config -DryRun
.\Bootstrap.ps1 -ConfigPath .\config -Approve
.\Repair.ps1 -ConfigPath .\config -DryRun
.\Repair.ps1 -ConfigPath .\config -OperationId <operation-id> -Approve
.\Install.ps1 -ConfigRoot .\config -DryRun
```

`Bootstrap.ps1` loads configuration, discovers state, compares it, builds one dependency-aware plan, previews or executes approved actions, re-discovers state, and writes timestamped JSON and Markdown reports. `-Approve` cannot bypass handler preconditions, dependency failures, interrupted-operation recovery, or destructive-operation safeguards. `-WhatIf` previews without invoking handlers. `-Component` limits the plan. Exit codes: `0` success or dry-run, `1` execution or verification failure, `2` approval required, `3` plan conflict.

`Repair.ps1` uses the same pipeline and reads the operation journal before planning recovery. Interrupted migrations, installations, PATH/environment changes, application settings, Docker, and WSL operations remain manual unless a provider supplies sufficient persisted rollback state. Targeted completed junction creation can be rolled back after target and ownership validation. Repair exit code `4` means manual recovery remains required.
