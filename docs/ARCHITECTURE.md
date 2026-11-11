# Architecture

## Design goals

DevData Bootstrapper is a Windows PowerShell 5.1-first system. It separates discovery from planning and execution so an audit can run safely, a dry run can explain proposed changes, and approved execution can be verified and recovered.

## Layers

### Entry points

- `Audit.ps1`: read-only discovery and drift reporting.
- `Bootstrap.ps1`: end-to-end discovery, comparison, planning, approval-gated execution, verification, and report entry point.
- `Install.ps1`: provider-based installation entry point; managed installation remains disabled by default.
- `Repair.ps1`: drift repair and journal-based recovery entry point.
- `Uninstall.ps1`: placeholder; removal is not implemented in this release candidate.

Each entry point will accept a configuration root, support `-DryRun` where applicable, and establish consistent logging/error behavior.

### `src/Core`

`Configuration.psm1` loads JSON and resolves runtime aliases; `Discovery.psm1` performs bounded read-only probes; `Comparison.psm1` emits classified findings; `Planner.psm1` converts findings into independent, non-executing actions; `Bootstrap.psm1` assembles the unified plan, validates conflicts, composes handlers, verifies state, and selects exit codes; `Recovery.psm1` reads journal state, classifies recovery safety, and creates only explicit recovery actions; `Repair.psm1` combines drift repair with recovery assessment; `Executor.psm1` runs approved actions through registered handlers; `State.psm1` persists operation journals; `Logger.psm1` writes sanitized JSONL records. `Reporting.psm1` sanitizes and writes JSON and Markdown reports. Core must not know how a specific tool is installed.

### `src/Install`

`WinGet.psm1` provides WinGet discovery, package queries, version-policy checks, and an approved install/verify handler. `OfficialInstallers.psm1` provides HTTPS/SHA256-gated archive and executable workflows with destination conflict checks. `Installation.psm1` turns only enabled, managed configuration entries into dependency-aware actions and registers handlers with the Core executor. `Install.ps1` is the entry point; it performs discovery and planning before routing execution through `Executor.psm1`.

### `src/Storage`

`Directories.psm1` handles ordinary-directory state and conflict-safe creation; `Migration.psm1` provides the transactional copy/verify/preserve/switch workflow and explicit recovery; `Junctions.psm1` distinguishes junctions from symbolic links, creates only missing links, and produces repair plans; `Verification.psm1` provides snapshots, hashes, capacity checks, and postcondition validation. Data movement must be explicit, resumable where practical, and protected by approval gates.

Storage migration order is: validate source/destination and application-stop probe, check capacity, snapshot source, copy with non-destructive Robocopy options or an injected provider, verify file hashes, preserve the source at a backup path, create the junction, and verify the final target. Failures leave recovery metadata and do not delete destination data or backups automatically.

### `src/Environment`

`Variables.psm1` models user, machine, and process environment values and exposes approved, idempotent variable actions. `Path.psm1` inspects duplicate/malformed entries, normalizes one entry at a time, and preserves unmanaged order and content. `PackageManagers.psm1` performs bounded npm, pnpm, Bun, uv, and related configuration discovery and provides native configuration actions where supported. All mutation handlers require an executor context/provider, explicit approval, preconditions, post-change verification, and recovery metadata.

### `src/Applications`

`Configuration.psm1` composes the environment, PATH, and package-manager adapters into a developer-configuration plan. It inventories binaries separately from profile/data locations, records explicit relocation support, and refuses to inspect credential-bearing paths. JSON settings actions merge only managed keys, preserve unrelated settings, create a provider backup before writing, and verify the result through the Executor contract.

### `src/Infrastructure`

`DockerWsl.psm1` provides bounded Docker Desktop/CLI, daemon, context, Docker WSL, WSL distribution, registry, VHDX metadata, and virtualization-prerequisite discovery. It also creates approval-gated Docker storage and WSL export/import/default-distribution plans. Docker storage relocation requires an explicitly supplied officially supported provider; WSL migration retains the original distribution and export archive. Infrastructure modules use the generic Core, Storage verification, and Executor contracts and never move active VHDX files directly.

### `src/Safety`

Approval policy, `Preconditions.psm1` checks, `Backup.psm1` provider interfaces, `Rollback.psm1` recovery interfaces, destructive-operation classification, lock/state handling, and postcondition verification.

## Execution handler contract

Future installer, storage, environment, or infrastructure modules register a handler by action type with `Executor.psm1`. A handler is an object exposing:

- required `Execute(Action, Context)` scriptblock;
- optional `TestPrecondition(Action, Context)` scriptblock returning a boolean or `{ Passed, Failures }` object;
- optional `Rollback(Action, Operation, Context)` scriptblock; and
- optional provider-specific metadata.

Handlers own domain behavior. The executor owns dependency ordering, approval gates, journal transitions, interruption checks, dry-run/WhatIf behavior, and sanitized logging. Installation and application-configuration handlers are provider-based; tests use mocks and temporary paths.

## Configuration

JSON is the source of desired state:

- `defaults.json`: schema version, behavior defaults, and safety policy.
- `applications.json`: applications/tools to discover or manage.
- `storage.json`: configurable roots and migration policies.
- `environment.json`: desired variables and PATH entries.
- `junctions.json`: desired link mappings and validation policy.
- `versions.json`: optional version constraints.

Values that identify a current user must use environment expansion or runtime resolution. Secrets are out of scope for repository configuration.

## Execution lifecycle

1. Load and validate all JSON configuration.
2. Discover current machine state using read-only probes.
3. Normalize state into stable records without exposing secrets.
4. Compare observed state with desired state.
5. Produce a plan with actions, risk, affected paths, and expected postconditions.
6. In dry-run mode, log the plan only.
7. In execution mode, require explicit approval for destructive or irreversible actions.
8. Create a backup/manifest before mutation where applicable.
9. Execute the smallest idempotent action set.
10. Verify each postcondition and record structured results.
11. Emit a summary and retain recovery information.

The current task includes provider-based environment and package-manager handlers, but no task entry point invokes them against the real machine. Tests use temporary state or mock providers; the malformed Go PATH remains untouched.

`Audit.ps1` now implements steps 1–5 and 11 for the read-only path. Reports are written to timestamped files under `logs\`. The planner records action IDs, dependencies, risk, affected paths, preconditions, approval requirements, safe-to-automate status, rollback context, and current status; it does not execute actions. The execution foundation accepts only explicitly registered handlers and persists every attempted operation to a caller-supplied journal.

## Safety invariants

- No mutation without an explicit execution path.
- No destructive operation without approval and recoverability checks.
- Never overwrite non-empty destinations silently.
- Never replace an existing directory with a junction without an explicit policy decision.
- Never remove PATH entries that are not owned by the bootstrapper.
- Never log secret values or read protected credential files.
- Every mutation has a verification step and a structured result.
