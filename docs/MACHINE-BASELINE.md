# Machine Baseline

Observed on 2026-11-11 (Asia/Dhaka), using read-only Windows PowerShell 5.1-compatible probes from the project workspace. Secret-bearing file contents were not read.

## Scope and evidence labels

- **Verified** means directly observed from filesystem metadata, registry metadata, environment APIs, or tool output.
- **Not inspected** means intentionally excluded because it could contain credentials or authentication material.
- **Assumption** is a design inference that needs confirmation before implementation.

## Verified operating environment

- Windows 11 was supplied as the host context.
- PowerShell 5.1 was the compatibility target supplied for this task. `pwsh` was not found on PATH.
- Effective user profile observed: `C:\Users\Rawad`.
- Machine architecture: AMD64.
- Processor count reported by the machine environment: 24.
- The workspace was empty before the foundation files were created.

## Developer-data roots

| Path | Observation |
|---|---|
| `D:\DevData` | Exists; immediate children include `AppData`, `Docker`, `Go`, `GoSDK`, `PackageManagers`, `Profile`, `Python`, and `tools`. |
| `D:\Projects` | **Missing**. |
| `D:\DevData\GoSDK\go` | Exists. |
| `D:\DevData\Go` | Exists. |
| `D:\DevData\Python` | Exists. |
| `D:\Program Files\nodejs` | Exists. |
| `D:\Docker\wsl` | Exists. |
| `D:\WSL\Ubuntu` | Exists. |

Approximate recursive file sizes for immediate `D:\DevData` children at inspection time:

| Child | Size |
|---|---:|
| `AppData` | 1.15 GB |
| `Docker` | 0 GB at displayed precision |
| `Go` | 0 GB at displayed precision |
| `GoSDK` | 0.23 GB |
| `PackageManagers` | 0.71 GB |
| `Profile` | 3.67 GB |
| `Python` | 0.31 GB |
| `tools` | 0.10 GB |

The total is approximately 6.17 GB. Sizes are estimates from readable files and may omit inaccessible files.

## Observed junctions

The bounded read-only reconciliation found 19 active developer-related directory junctions: 11 profile junctions, 5 `AppData\Local` junctions, and 3 `AppData\Roaming` junctions. All observed targets existed at reconciliation time.

| Link | Target |
|---|---|
| `C:\Users\Rawad\.agents` | `D:\DevData\Profile\.agents` |
| `C:\Users\Rawad\.cache` | `D:\DevData\Profile\.cache` |
| `C:\Users\Rawad\.caveman` | `D:\DevData\Profile\.caveman` |
| `C:\Users\Rawad\.claude` | `D:\DevData\Profile\.claude` |
| `C:\Users\Rawad\.copilot` | `D:\DevData\Profile\.copilot` |
| `C:\Users\Rawad\.cursor` | `D:\DevData\Profile\.cursor` |
| `C:\Users\Rawad\.docker` | `D:\DevData\Profile\.docker` |
| `C:\Users\Rawad\.gemini` | `D:\DevData\Profile\.gemini` |
| `C:\Users\Rawad\.local` | `D:\DevData\Profile\.local` |
| `C:\Users\Rawad\.vscode` | `D:\DevData\Profile\.vscode` |
| `C:\Users\Rawad\.vscode-shared` | `D:\DevData\Profile\.vscode-shared` |
| `C:\Users\Rawad\AppData\Local\claude-cli-nodejs` | `D:\DevData\AppData\Local\claude-cli-nodejs` |
| `C:\Users\Rawad\AppData\Local\copilot` | `D:\DevData\AppData\Local\copilot` |
| `C:\Users\Rawad\AppData\Local\Cursor` | `D:\DevData\AppData\Local\Cursor` |
| `C:\Users\Rawad\AppData\Local\npm-cache` | `D:\DevData\AppData\Local\npm-cache` |
| `C:\Users\Rawad\AppData\Local\uv` | `D:\DevData\AppData\Local\uv` |
| `C:\Users\Rawad\AppData\Roaming\Code` | `D:\DevData\AppData\Roaming\Code` |
| `C:\Users\Rawad\AppData\Roaming\Cursor` | `D:\DevData\AppData\Roaming\Cursor` |
| `C:\Users\Rawad\AppData\Roaming\uv` | `D:\DevData\AppData\Roaming\uv` |

Backup-looking sibling directories were visible for some links, including `claude-cli-nodejs.C-backup`, `copilot.C-backup`, `Cursor.C-backup`, `npm-cache.C-backup`, `Code.C-backup`, and `Roaming\Cursor.C-backup`. They are ordinary directories with no junction link type and are not included in the managed inventory. Legacy shell compatibility reparse points such as `Application Data`, `Cookies`, and `Recent` were also excluded because they are not active developer-data junctions and did not expose managed junction targets.

## Tools and versions

| Tool | Observed version/path |
|---|---|
| Git | 2.56.0.windows.4; `D:\Program Files\Git\cmd\git.exe` |
| Python | 3.12.16; uv-managed interpreter under `D:\DevData\Python\uv-python` |
| uv | 0.13.7; installed via WinGet package path |
| Node.js | v26.13.0; `D:\Program Files\nodejs\node.exe` |
| npm | 11.20.0; prefix `D:\DevData\PackageManagers\npm-global`; cache `D:\DevData\PackageManagers\npm-cache` |
| pnpm | 12.18.0; store `D:\DevData\PackageManagers\pnpm-store` |
| Bun | 1.4.4; home `D:\DevData\PackageManagers\.bun` |
| Go | go1.27.3 windows/amd64; `GOROOT=D:\DevData\GoSDK\go` |
| Docker | 29.9.3; Docker Compose v5.7.0 |
| VS Code | 1.146.0; `D:\Program Files\Microsoft VS Code` |
| Cursor | 3.29.15; `D:\Program Files\cursor` |
| WSL | 3.0.5.0 |

Registry installation metadata also listed Docker Desktop 4.99.0 and Git 2.56.0.4. Registry metadata did not list a conventional Python or Go installer; both appear to be managed/extracted into `D:\DevData`.

## Environment and PATH

Verified user variables include:

- `GOBIN=D:\DevData\Go\bin`
- `GOCACHE=D:\DevData\Go\cache`
- `GOMODCACHE=D:\DevData\Go\pkg\mod`
- `GOPATH=D:\DevData\Go`
- `GOROOT=D:\DevData\GoSDK\go`
- `PIP_CACHE_DIR=D:\DevData\Python\pip-cache`
- `PNPM_HOME=D:\DevData\PackageManagers\pnpm-home`
- `BUN_INSTALL=D:\DevData\PackageManagers\.bun`
- `UV_CACHE_DIR=D:\DevData\Python\uv-cache`
- `UV_PYTHON_BIN_DIR=D:\DevData\Python\uv-bin`
- `UV_PYTHON_INSTALL_DIR=D:\DevData\Python\uv-python`
- `UV_TOOL_BIN_DIR=D:\DevData\Python\uv-bin`
- `UV_TOOL_DIR=D:\DevData\Python\uv-tools`

The machine PATH contains Windows, VS Code, Docker, WSL, Node.js, and Git locations. The user PATH contains the drive-backed Python, package-manager, Go, and Node.js locations. The raw user PATH has:

- a combined entry rendered as `D:\DevData\GoSDK\go\bin D:\DevData\Go\bin`, which is not a normal semicolon-separated PATH entry and requires confirmation/repair planning;
- separate duplicate entries for `D:\DevData\GoSDK\go\bin` and `D:\DevData\Go\bin`; and
- a duplicate `D:\Program Files\nodejs` entry across machine and user PATH scopes.

No PATH changes were made.

## Python, Go, npm, pnpm, Bun, and uv configuration

- Python resolves to `D:\DevData\Python\uv-python\cpython-3.12.16-windows-x86_64-none\python.exe`.
- `py.exe` was not found.
- Python user site is the default `C:\Users\Rawad\AppData\Roaming\Python\Python312\site-packages`.
- uv cache and Python installation directories are drive-backed as listed above.
- npm user config path reported as `C:\Users\Rawad\.npmrc`; its contents were not read because it may contain registry credentials.
- Go environment file path reported as `C:\Users\Rawad\AppData\Roaming\go\env`; its contents were not read.

## Docker and WSL

- WSL default distribution: `docker-desktop`.
- WSL default version: 2.
- Registered distributions: `docker-desktop` (Stopped, version 2) and `Ubuntu` (Stopped, version 2).
- Registry metadata reports `docker-desktop` storage at `\\?\D:\Docker\wsl\main` and `Ubuntu` storage at `D:\WSL\Ubuntu`.
- Docker contexts are `default` and `desktop-linux`; `desktop-linux` is active.
- `D:\Docker\wsl` contains `main` and `disk` directories.

## Intentionally not inspected

- `.ssh` contents/private keys.
- `.docker` contents, Docker auth files, and Docker credential databases.
- `.config` contents.
- npm user config contents, Go environment-file contents, browser data, tokens, passwords, and application credential databases.
- WSL filesystem contents and Docker virtual disk contents.

These paths were only checked for existence or metadata when needed to establish links/locations.

## Discrepancies and assumptions needing confirmation

1. `D:\Projects` is absent despite being the intended projects root.
2. The user PATH contains a malformed-looking combined Go entry and duplicates. This should be treated as audit drift, not automatically repaired.
3. Python user site remains on `C:` while the managed interpreter and caches are on `D:`; whether that is intentional is unknown.
4. The registry reports WSL storage paths consistent with the stated setup, but distribution state was stopped during inspection.
5. The future bootstrapper must resolve the current username at runtime; `Rawad` is baseline evidence only, never a software default.
