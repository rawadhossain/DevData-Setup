# Audit Guide

Audit is read-only.

```powershell
.\Audit.ps1 -ConfigRoot .\config
```

The audit discovers Windows and PowerShell, drives, configured directories, installed software, environment scopes, PATH entries, package managers, Python/uv, Go, Docker, WSL, junctions, and configured application state.

Reports are timestamped under `logs\`:

- JSON: machine-readable findings and plan.
- Markdown: reviewable summary.

Each finding contains component, expected state, actual state, status, classification, recommended action, and automation safety. Statuses are `PASS`, `WARNING`, `MISMATCH`, `MISSING`, and `UNKNOWN`.

Audit never installs, moves, deletes, creates junctions, changes PATH, changes environment variables, exports WSL, or moves Docker storage. Credential-bearing files are not inspected.

Review `MISMATCH` and `MISSING` findings first. Treat `WARNING` and `UNKNOWN` as review items, not automatic repair authorization.
