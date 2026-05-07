# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ClawdHome is a **macOS native app** (Swift 5.9 / SwiftUI / macOS 14+) that securely isolates and manages multiple OpenClaw gateway instances ("Shrimps") on a single Mac using native multi-user primitives. Each Shrimp maps to a standard macOS user account with its own runtime, data, and permissions.

## Build & Development Commands

```bash
# Build (Debug) — App + Helper
make build

# Build Helper only
make build-helper

# Install helper daemon (requires sudo)
make install-helper

# Uninstall helper daemon
make uninstall-helper

# Build release archive
make build-release

# Package .pkg installer
make pkg

# Full release (pkg + version sync + release notes)
make release

# Run i18n checks (untranslated strings, placeholder consistency, legacy string usage)
make i18n-check

# View helper logs
make log-helper          # tail -f /tmp/clawdhome-helper.log

# View app logs (os_log)
make log-app

# Clean build artifacts
make clean

# Regenerate Xcode project from project.yml (requires XcodeGen)
xcodegen generate
```

There are no unit tests configured in this project.

## Architecture

### Privilege Separation (Core Design)

```
ClawdHome.app (user context, SwiftUI)
    └── XPC (NSXPCConnection, Mach service) ──→ ClawdHomeHelper (root LaunchDaemon)
                                                   └── per-user OpenClaw gateway instances
```

The app **never** performs privileged operations directly. All system-level actions route through the XPC helper.

### Two Targets (defined in `project.yml`, built via XcodeGen)

| Target | Type | Bundle ID | Role |
|--------|------|-----------|------|
| `ClawdHome` | .app | `ai.clawdhome.mac` | Admin UI — SwiftUI frontend, state management, XPC client |
| `ClawdHomeHelper` | tool | `ai.clawdhome.mac.helper` | Privileged daemon — user/process/file ops as root |

The helper binary is embedded into the app bundle at `Contents/Library/LaunchDaemons/` via a post-build script.

### Shared Code (`Shared/`)

- `HelperProtocol.swift` — the **single XPC interface** (`ClawdHomeHelperProtocol`, `@objc` protocol). All app↔helper communication goes through this protocol. XPC methods must use ObjC-compatible types only.
- `*Models.swift` — Codable model types shared between both targets (Dashboard, Process, File, Network, HealthCheck, CloneClaw, LocalAI).

### App Layer (`ClawdHome/`)

- **Services/** — business logic and infrastructure:
  - `HelperClient` — XPC connection manager with **5 dedicated connections** (control, dashboard, install, file, process) to avoid blocking.
  - `ShrimpPool` — manages the collection of Shrimp instances and their lifecycle state.
  - `GatewayHub` / `GatewayClient` — HTTP clients for communicating with running gateway instances.
  - `ProviderKeychainStore` / `UserPasswordStore` — Keychain-backed credential storage.
  - `WizardConnection` — manages the init wizard flow for new Shrimps.
- **Models/** — app-side state objects (`ManagedUser`, `GlobalModelStore`, `GlobalSecretsStore`, `AccountKeychain`, `ProviderKeyConfig`).
- **Views/** — SwiftUI views. Key screens: `DashboardView`, `UserDetailView`, `UserInitWizardView`, `ClawPoolView`, `ModelManagerView`, `UserFilesView`.

### Helper Layer (`ClawdHomeHelper/`)

- `main.swift` — daemon entry point, XPC listener setup, JSONL logging with rotation.
- **Operations/** — privileged operations organized by domain:
  - `UserManager` — create/delete macOS users via `sysadminctl`/`dscl`.
  - `GatewayManager` — start/stop/restart gateways via `launchctl`.
  - `InstallManager` — install Node.js/OpenClaw via npm.
  - `UserFileManager` — file CRUD within user home directories.
  - `ProcessManager` — list/kill user processes.
  - `ConfigWriter` — read/write OpenClaw JSON config files.
  - `DashboardCollector` / `ConnectionCollector` / `NStatCollector` — system metrics.
  - `LocalLLMManager` — manage local AI model service (omlx).
  - `ShellRunner` — generic shell command execution as specific users.

### State Management

Uses Swift `@Observable` (Observation framework) throughout. Key observable objects are injected via SwiftUI `.environment()` from `ClawdHomeApp.swift`: `HelperClient`, `ShrimpPool`, `UpdateChecker`, `GlobalModelStore`, `ProviderKeychainStore`, `GatewayHub`, `AppLockStore`.

### Versioning

Build numbers are **auto-derived** from git commit count (`git rev-list --count HEAD`). Version format: `1.1.<commit-count>`. No manual version bumping needed.

## Localization

- Uses **Stable.xcstrings** (Apple's modern string catalog format).
- Supported languages: English + Chinese.
- CI enforcement via three Python scripts in `scripts/`:
  - `i18n_check_untranslated.py` — finds untranslated strings.
  - `i18n_ci_check.py` — validates translation completeness and placeholder consistency.
  - `i18n_forbid_legacy_t.py` — ensures no legacy `NSLocalizedString` usage.
- Run all checks: `make i18n-check`.

## Key Paths at Runtime

| Path | Purpose |
|------|---------|
| `/tmp/clawdhome-helper.log` | Helper JSONL log (2MB max, 3 rotations) |
| `/var/lib/clawdhome/` | Helper persistent state (init progress, debug flag, autostart config) |
| `/var/lib/clawdhome/cache/` | Helper installation cache (homebrew, nodejs) — root only |
| `/var/lib/clawdhome/models/` | Local AI models (omlx) — root only |
| `/Users/Shared/ClawdHome/` | Cross-user shared file space (public folder, per-shrimp vaults) |
| `~<shrimp>/.openclaw/` | Per-Shrimp OpenClaw config and data |
| `~<shrimp>/.npm-global/` | Per-Shrimp npm global install directory |

## Conventions

- Code comments and Makefile help text are in **Chinese**.
- XPC protocol changes require updating `Shared/HelperProtocol.swift` — both targets compile this file.
- The helper runs as a LaunchDaemon (`/Library/LaunchDaemons/ai.clawdhome.mac.helper.plist`). During development, use `make install-helper` to deploy it.
- JSON is the serialization format for complex data passed over XPC (encoded as String, decoded on both sides using shared Codable models).
