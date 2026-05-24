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
                                                   ├── per-user browser-account isolation layer
                                                   │    └── managed Chrome profile + Browser Bridge/CDP session
                                                   └── per-user OpenClaw / Hermes runtime instances
```

The app **never** performs privileged operations directly. All system-level actions route through the XPC helper.

### Browser Isolation Layer

ClawdHome has a second isolation boundary in addition to macOS user separation: a **per-Shrimp browser-account layer**. This layer lives under the Shrimp user's `~/.clawdhome/browser` namespace and exposes a managed browser profile plus transport metadata that runtimes can consume.

- Isolation unit: one Shrimp user owns one browser-account namespace; other Shrimp users cannot read its cookies, session files, profile selectors, or CDP metadata.
- Shared inside the boundary: OpenClaw and Hermes intentionally reuse the same browser-account layer for the same Shrimp so they can share login state without sharing the host operator's real browser profile.
- Transport fan-out: the browser-account layer can provide `OPENCLI_PROFILE` for Browser Bridge/OpenCLI integration and `BROWSER_CDP_URL` / DevTools session metadata for CDP-aware runtimes.
- Security intent: automation traffic is routed to a ClawdHome-managed browser profile, not to the operator's default Chrome profile, so "external browser" support still stays inside the Shrimp boundary.

Detailed reference: `docs/browser-account-technical-spec.md`

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
- **Models/** — app-side state objects (`ManagedUser`, `GlobalModelStore`, `GlobalSecretsStore`, `ProviderKeyConfig`).
- **Views/** — SwiftUI views. Key screens: `DashboardView`, `UserDetailView`, `UserInitWizardView`, `ClawPoolView`, `ModelManagerView`, `UserFilesView`.

### Helper Layer (`ClawdHomeHelper/`)

- `main.swift` — daemon entry point, XPC listener setup, JSONL logging with rotation.
- **Operations/** — privileged operations organized by domain:
  - `UserManager` — create/delete macOS users via `sysadminctl`/`dscl`.
  - `GatewayManager` — start/stop/restart gateways via `launchctl`.
  - `HermesGatewayManager` — start/stop/restart Hermes gateways via `launchctl`.
  - `InstallManager` — install Node.js/OpenClaw via npm.
  - `HermesInstaller` — install/upgrade Hermes Agent and build its isolated runtime env.
  - `BrowserAccountManager` — provision the managed browser profile, Browser Bridge/OpenCLI wrappers, session files, and CDP metadata shared by runtimes within one Shrimp boundary.
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
  - `i18n_ci_check.py` — validates translation completeness, placeholder consistency, and rejects auto-titlecased English placeholders (allowlist at `scripts/i18n_placeholder_en_allowlist.json` for legacy debt).
  - `i18n_forbid_legacy_t.py` — ensures no legacy `NSLocalizedString` usage.
- Run all checks: `make i18n-check`.

### i18n UI Rules (mandatory — agents MUST follow)

When you add or edit any `L10n.k(...)` / `L10n.f(...)` call, or write to `Stable.xcstrings`:

1. **Always supply BOTH a Chinese and a real English translation.** Never leave the English blank — Xcode auto-fills it with the title-cased key (e.g. `"Views Detail Config Source Picker"`), which renders as broken UI in English locale and is rejected by `make i18n-check`.
2. **Length budgets** (English chars; Chinese ≈ half — see `docs/i18n-style.md` for examples):
   - Segmented Picker / Tab option: **≤ 12 chars**
   - Picker label / form field label: **≤ 14 chars**
   - Button title: **≤ 14 chars**
   - Table header / column name: **≤ 16 chars**
3. **Translation style:** prefer single nouns/verbs over phrases — `Source` not `Configuration Source`, `New` not `Create New One`, `Pool` not `From Global Pool`.
4. **`Picker` with `.pickerStyle(.segmented)` and ≥ 4 options:** the picker's built-in label gets squeezed to vertical text. Use `.labelsHidden()` and put a separate `Text(...)` label above the picker if a label is needed.
5. **CI gates** (`make i18n-check` must pass before commit):
   - **Error**: new keys with English value equal to the title-cased key → blocked. Exceptions go in `scripts/i18n_placeholder_en_allowlist.json` only as temporary historical-debt markers.
   - **Error**: when you fix a translation that was on the allowlist, **remove the key from the allowlist** in the same change — CI flags stale entries.
   - **Warning**: English visual width > Chinese × 2 for label-style strings (≤ 30-char, single-line, no sentence punctuation). Doesn't block CI but indicates likely UI overflow — shorten the English or restructure the control. CJK char counts as 2 visual units.

Full reference with examples and anti-patterns: **`docs/i18n.md`** (§ "UI Translation Style Rules").

## Key Paths at Runtime

| Path | Purpose |
|------|---------|
| `/tmp/clawdhome-helper.log` | Helper JSONL log (2MB max, 3 rotations) |
| `/var/lib/clawdhome/` | Helper persistent state (init progress, debug flag, autostart config) |
| `/var/lib/clawdhome/cache/` | Helper installation cache (homebrew, nodejs) — root only |
| `/var/lib/clawdhome/models/` | Local AI models (omlx) — root only |
| `/Users/Shared/ClawdHome/` | Cross-user shared file space (public folder, per-shrimp vaults) |
| `~<user>/.clawdhome/` | Per-user ClawdHome config and browser-tool directory, shared by OpenClaw, Hermes, and future runtimes |
| `~/Library/Application Support/ClawdHome/BrowserProfiles/<shrimp>/` | Managed Chrome profile owned by one Shrimp browser account; Browser Bridge extension and DevToolsActivePort live here |
| `~<shrimp>/.clawdhome/browser/session.json` | Active browser session metadata (profile path, CDP endpoint, websocket debugger URL) for the Shrimp-scoped browser account |
| `~<shrimp>/.clawdhome/browser/opencli-profile.json` | Persisted Browser Bridge/OpenCLI profile selector for the Shrimp-scoped browser account |
| `~<shrimp>/.clawdhome/runtime.json` | Runtime type anchor: `{"runtime":"hermes"}` or `{"runtime":"openclaw"}` — written on install, read by identification engine; absent → falls back to openclaw detection |
| `~<shrimp>/.openclaw/` | Per-Shrimp OpenClaw config and data |
| `~<shrimp>/.npm-global/` | Per-Shrimp npm global install directory |
| `~<shrimp>/.hermes/` | Per-Shrimp Hermes Agent main profile (HERMES_HOME) |
| `~<shrimp>/.hermes/profiles/<id>/` | Named Hermes profile (independent HERMES_HOME) |
| `~<shrimp>/.hermes/[profiles/<id>/].clawdhome_wizard_state.json` | Per-profile team wizard progress bitmap |
| `/var/lib/clawdhome/<shrimp>-hermes-autostart.json` | Per-profile Hermes autostart whitelist |
| `/Library/LaunchDaemons/ai.clawdhome.hermes.<shrimp>[.<id>].plist` | Per-profile Hermes gateway launchd unit |

## Hermes Multi-Profile / Team Wizard

A single Shrimp can host multiple Hermes profiles (agent personas), each living in its own isolated HERMES_HOME with independent `config.yaml` / `.env` / gateway process / sessions / skills / memories / cron / logs. The `main` profile maps to `~<shrimp>/.hermes/` itself; named profiles live under `~<shrimp>/.hermes/profiles/<id>/`. This mirrors hermes-agent's native profile model — `hermes -p <id> ...` and `hermes profile list/use` work as documented upstream.

**Key invariants**:
- Each profile = one launchd unit. Label rule: `main` retains the legacy `ai.clawdhome.hermes.<shrimp>` (backward compatible); named profiles append `.<id>`.
- Boot autostart is gated by both the per-Shrimp sentinel `/var/lib/clawdhome/<shrimp>-autostart-disabled` and the per-profile whitelist `/var/lib/clawdhome/<shrimp>-hermes-autostart.json`. Whitelist file missing ⇒ falls back to `["main"]` (backward compatible).
- A profile creation via `HermesProfileManager.createProfile` automatically adds it to the whitelist (default-on); `removeProfile` strips it. Users can opt out per profile via the "开机启动" toggle on each card in `HermesDetailView`.
- IM bindings write to the profile's `.env`. Token-based platforms (Telegram/Slack/Discord/feishu/wecom/dingtalk/email/signal/matrix/mattermost) take a form; QR-based platforms (whatsapp/weixin) launch `MaintenanceTerminalSession` running `hermes -p <id> <subcmd>` for scan-to-pair, with a 5-minute deferred fallback if the user closes the terminal early.

**Entry point**: `HermesDetailView` sidebar → "团队初始化" button opens `HermesTeamWizard` (6 steps: install → members → shared LLM config → IM bindings → gateway start → summary). The wizard persists per-profile progress and resumes from the first incomplete step on reopen.

**Design references**:
- `docs/plans/2026-04-25-hermes-team-wizard-design.md` — full design (decisions D1-D12, data layout, XPC contracts, plist templates, error codes, UI sketches)
- `docs/plans/2026-04-25-hermes-team-wizard-tasks.md` — 21-task breakdown across 6 PRs

**Known follow-ups** (deliberately out of the multi-profile workflow scope):
- i18n: new Hermes UI views still use raw CJK literals (~116 unique strings); a separate PR will migrate them to `L10n.k(...)` / `L10n.f(...)` and clear the project's pre-existing i18n debt in `AddProviderModelSheet` / `ShrimpInitWizardV2` / `ShrimpSettingsV2View`.
- `hermes-intentional-stop` sentinel: hermes intentionally does **not** mirror OpenClaw's intentional-stop mechanism — autostart is whitelist-driven (D7).

## Runtime Browser Integration

The browser-account layer is runtime-agnostic; OpenClaw and Hermes consume it through different environment/config injection points.

- OpenClaw receives the Shrimp-scoped browser selectors through the shared user runtime environment (notably `OPENCLI_PROFILE`) and the `BROWSER` wrapper command that targets ClawdHome's managed browser tool.
- Hermes receives the same `BROWSER` wrapper plus `OPENCLI_PROFILE`, and when a reachable DevTools endpoint exists it also receives `BROWSER_CDP_URL`; ClawdHome additionally syncs that endpoint into Hermes `config.yaml` as `browser.cdp_url`.
- Because both engines read from the same Shrimp browser-account namespace, switching engines does not require re-login, while cross-Shrimp leakage is still blocked by the macOS user boundary.

## Conventions

- Code comments and Makefile help text are in **Chinese**.
- XPC protocol changes require updating `Shared/HelperProtocol.swift` — both targets compile this file.
- The helper runs as a LaunchDaemon (`/Library/LaunchDaemons/ai.clawdhome.mac.helper.plist`). During development, use `make install-helper` to deploy it.
- JSON is the serialization format for complex data passed over XPC (encoded as String, decoded on both sides using shared Codable models).
- **No demo or mock data anywhere** — every code path must use real data. If real data isn't available yet, surface the empty/loading state rather than fabricating values.

## Agent Tooling
- When an agent commits code on your behalf, use English for the commit summary and description.


`AGENTS.md` is a symlink to this file so that Codex CLI, Cursor, and other agent tools that follow the `AGENTS.md` convention pick up the same instructions Claude Code uses. Edit `CLAUDE.md` only — `AGENTS.md` stays in sync automatically.
