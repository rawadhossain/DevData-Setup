# Release Candidate Checklist

## Completed

- [x] JSON configuration validates.
- [x] PowerShell files parse under Windows PowerShell 5.1 parser.
- [x] Full Pester suite passes with mock and temporary-directory tests.
- [x] Reports and logs redact secret-shaped values.
- [x] Dry-run, WhatIf, approval, dependency, journal, and recovery paths tested.
- [x] Machine-specific username is absent from configuration and source logic.
- [x] Generated logs and graph artifacts are ignored by `.gitignore`.

## Blockers before production use

- [ ] Validate approved installation and migration providers on a disposable Windows machine.
- [ ] Validate administrator-required machine-scope, junction, Docker, and WSL operations.
- [ ] Add durable provider recovery metadata before unattended recovery is considered.
- [ ] Decide whether to implement uninstall; it is currently a placeholder.
- [ ] Review current machine baseline and replace observed paths for each target machine.
- [ ] Create a private repository and review generated logs before committing.

## Release warning

`0.1.0-rc.1` is experimental. Tests do not prove safe operation against every Windows build, filesystem, provider version, application lock, or storage failure. Use dry-run first and keep independent backups.

Report defects with Windows version, PowerShell version, command line, sanitized report, action ID, operation ID, and reproduction steps. Never attach credentials, tokens, private keys, Docker auth files, or personal application data.
