# Implementation Plan

## Milestone 0 — Foundation and baseline (implemented)

Delivered the repository layout, configuration contracts, machine baseline, architecture, safety principles, and entry points. Release documentation is maintained separately.

## Milestone 1 — Core contracts and discovery (implemented in Task 002)

Implemented configuration loading/validation, safe path helpers, secret redaction, and read-only discovery for files, directories, junctions, environment variables, PATH, installed software, drives, package managers, Python/uv, Go, Docker, and WSL.

Tests: JSON fixtures, path normalization, redaction, deterministic diffs, missing/inaccessible-path handling, and Pester tests running without admin rights.

## Milestone 2 — Audit and planning (implemented in Task 003)

`Audit.ps1` now runs discovery, comparison, independent non-executing planning, and writes stable human-readable Markdown plus machine-readable JSON reports. Findings cover applications, optional versions, package-manager paths, Python/uv, Go, environment scopes, drive capacity, and junction enablement. No mutation.

Completion: a fresh machine and the current baseline produce actionable, non-secret audit reports.

## Milestone 3 — Execution safety foundation (implemented in Task 004)

Implemented generic dependency-ordered execution, dry-run/WhatIf, approval gates, precondition checks, persistent operation journals, interrupted-operation detection, duplicate-completion prevention, sanitized structured logging, and provider-based backup/rollback interfaces. Only mock handlers are tested; no real mutation handler exists.

## Milestone 4 — Safe environment and junction operations (storage foundation implemented in Task 005)

Storage directory creation, migration, junction creation/validation/repair planning, verification, backup preservation, and explicit recovery interfaces are implemented. Environment variable, PATH, and package-manager providers now support mockable comparison and approved action handlers, and Task 006.1 wires their read-only discovery and comparison into `Audit.ps1`. Real host mutation remains disabled for this task. Start future execution with a narrow allowlist and explicit approval.

Tests: existing directory, missing target, conflicting path, wrong junction target, duplicate/malformed PATH, scoped environment persistence, package-manager comparisons, rollback metadata, and repeated execution.

## Milestone 5 — Application and runtime adapters (installation and Docker/WSL foundations implemented)

WinGet and official HTTPS archive/executable installation providers now support discovery, planning, approved execution, version checks, destination conflict checks, verification, and recovery metadata. Application configuration adapters and Docker/WSL discovery/planning now use the same provider and Executor contracts. Docker storage relocation remains provider-gated; WSL export/import retains originals and backups. Configuration entries remain disabled for management by default.

Completion: each adapter can discover, plan, execute (where enabled), and verify independently.

## Milestone 6 — End-to-end orchestration (implemented in Task 010)

`Bootstrap.ps1` loads and validates configuration, discovers and compares state, builds a unified dependency-aware plan, checks conflicts, previews or executes through `Executor.psm1`, verifies with a second discovery pass, and emits JSON/Markdown reports. It supports `-ConfigPath`, `-ReportPath`, `-Component`, `-DryRun`, `-WhatIf`, and `-Approve`. Real machine execution remains opt-in and handler/provider gated.

Tests cover mocked fresh and matching states, approval gating, dry-run, satisfied-action skipping, conflict detection, report generation, and existing module compatibility.

## Milestone 7 — Data migration (implemented in Task 005)

Implemented manifest-based migration handlers for approved application data and caches. The workflow uses copy/verify/switch/rollback phases, preserves source backups, rejects nested paths, and handles junctions only after validation.

Tests: empty source, populated source, partial copy, locked file, insufficient space, interrupted migration, and rollback.

## Milestone 8 — Repair and uninstall

Repair and journal recovery are implemented in Task 011. `Repair.ps1` reuses discovery, comparison, planning, Executor, reporting, and operation journals. Recovery classification is conservative: interrupted destructive operations remain manual; only completed junction creation has an automatic rollback path because its handler validates the current target. Recovery attempts use separate journal actions and approval gates.

Next: extend targeted repair coverage and implement a conservative uninstall path. Uninstall must remove only bootstrapper-owned state and never delete user data without separate confirmation.

## Milestone 9 — Release candidate preparation (implemented in Task 013)

Added configuration, installation, audit, bootstrap, repair/recovery, troubleshooting, changelog, and release-checklist documentation. Version `0.1.0-rc.1` is experimental. Runtime logs, backups, temporary files, and graph artifacts remain ignored; machine-baseline evidence remains preserved.

## Dependencies and constraints

- Windows PowerShell 5.1 compatibility is the primary constraint.
- Pester is the test framework; avoid runtime dependencies unless a concrete adapter requires one.
- Administrator privileges may be required for some machine-scope or WSL operations; detection must distinguish unavailable privilege from misconfiguration.
- GitHub integration is postponed.

## Completion criteria for the project

- Fresh and existing Windows machines can be discovered without mutation.
- Desired state is configurable and username/drive independent.
- Dry-run output is deterministic and understandable.
- Mutations are idempotent, approval-gated, backed up, and verified.
- Repair and rollback paths are tested with fixtures.
- Logs contain structured outcomes without secrets.
