# Configuration Reference

Configuration lives in `config\`. JSON is portable and resolved at runtime.

## Files

- `defaults.json`: platform, path aliases, capacity threshold, safety policy, and logging defaults.
- `applications.json`: discoverable applications and optional managed installation definitions.
- `storage.json`: developer-data roots, Docker/WSL destinations, and migration policy.
- `environment.json`: managed user variables, package-manager settings, PATH entries, and cleanup policy.
- `junctions.json`: source/target mappings and junction safety policy.
- `versions.json`: optional minimum and maximum version constraints.

## Path aliases

Use `%DEVDataRoot%`, `%ProjectsRoot%`, `%DockerWslRoot%`, `%UbuntuWslRoot%`, `%USERPROFILE%`, and `%USERNAME%`. Do not put a real username in configuration.

The baseline uses `D:\` as observed machine data. Portable configurations may replace these aliases with another drive or root.

## Enablement and mutation

- `applications[].enabled` controls discovery/planning visibility.
- `applications[].managed` must be `true` before installation planning occurs.
- `junctions.enabled` controls junction mutation planning.
- `storage.docker.relocation.enabled` controls Docker relocation planning.
- `storage.wsl.distributions[].migration.enabled` controls WSL export/import planning.
- `storage.migration.enabled` controls ordinary directory migration policy.

All mutation actions require Executor approval. Disabled components remain visible in audit results but produce no executable action.

## Safety defaults

Defaults preserve unmanaged PATH entries, require backups, verify postconditions, preserve migration sources, reject non-empty destinations, and disable migrations, junction mutation, Docker relocation, and WSL migration.

Do not store credentials, tokens, SSH keys, Docker authentication data, or application credential files in this repository.
