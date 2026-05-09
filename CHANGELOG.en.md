# Changelog

## [1.10.0] - 2026-05-10

### New Features

- **Browser Account Bridge**: Agents access external services through your existing browser sessions — no re-authorization needed; OpenCLI and Hermes/OpenClaw share a unified account channel with persistent login state and isolated sessions.
- **Prompt Memory & Library**: New Prompt Memory overlay and global Prompt Library with search, tag filters, and Quick Note launcher; ships with a curated set of built-in templates.
- **Hermes × OpenClaw Dual-Engine Polish**: Independent install interface, multi-tab terminal switching, per-profile start/stop controls, batch actions, and autostart — both engines fully self-contained.
- **Global Model Pool Redesign**: Grouped by provider with live search and dynamic model list fetching; supports custom channels, API connectivity tests, and drag-to-reorder fallback priority.
- **Backup & Restore**: Snapshots, incremental backups, and one-click restore.
- **Embedded Multi-Tab Terminal**: Replaces the old maintenance window with output search, theme switching, and tab cloning; full output fidelity with no truncation, automatic cleanup.
- **Vault File Sharing**: New secure folder, public folder, and cross-Shrimp shared space; Agents automatically get the tool access they need, with on-demand permission repair.
- **File Manager Upgrades**: Copy, move, and bulk-delete files and folders; column sorting and a freely resizable text editor window.
- **Settings Panel Redesign**: Settings moved to a sidebar tab; IM bindings and Agent management unified in one place for a shorter navigation path.
- **Unified Diagnostics Center**: Six checks (environment, permissions, config, security, gateway, network) in one click; engine-specific branches, health probe, force restart, and disconnection banner.
- **ClawdHome CLI**: Docker-style commands (`init`, `exec`, …) with no nested `shrimp` subcommands.
- **Appearance & Upgrade UX**: System / Light / Dark appearance toggle; upgrade animations, notifications, and shortcuts all refreshed.
- **Chrome Environment Isolation**: ClawdHome manages only its own browser environment — your everyday Chrome is never affected.
- **Internationalization Pass**: Hardcoded strings fully cleaned up; English translations are accurate and natural — no more placeholder text.

### Improvements & Fixes

- Resolved OpenCLI cold-start failures and daemon ordering issues — first launch and restart are much more reliable
- Fixed blank screens, black screens, and display glitches in embedded WebView interfaces
- Fixed IM channel backward compatibility with legacy configs; channel pairing now stays open after completion
- Localized remaining hardcoded strings across wizard, detail pages, and binding flows
- Additional stability, compatibility, and layout polish improvements


## [1.9.0] - 2026-04-28

# New Features
- Hermes Agent Engine Support: Added a second engine, Hermes Agent, which can coexist with OpenClaw. Supports an independent installation interface, maintenance terminal environment isolation, and engine-aware diagnostics.
- OpenClaw Multi-Agent Management: A single openclaw instance now supports creating and deleting multiple Agents, with each Agent independently configuring identity, models, and IM bindings.
- Role Marketplace Supports Multi-Agent: A single Agent definition can support multiple IM bindings, allowing you to summon a team with one click.
- Shrimp Pond Card Full Redesign: Shrimp Pond card width is now adaptive, displaying the number of Agents (roles) in real-time.
- Settings Panel Refactoring: Settings items have been moved to an independent tab in the details sidebar. IM bindings and Agent management are presented uniformly for clearer operation paths.
- Custom Model Channels: Supports adding custom Provider channels, providing global template selection and API credential connectivity testing. Agent model configuration is changed to a dropdown selection.
- Maintenance Terminal Upgrade: The maintenance terminal now includes output content search, theme switching, tab cloning, and rate-limiting protection.
- File Management Upgrade: The file list supports multi-selection batch deletion and column sorting. The text editing window supports free drag-to-resize.

# Improvements & Fixes
- Optimized the stability of Gateway auto-start on boot, adding an automatic retry mechanism for bootstrap failures.
- After creating or deleting an Agent, the Gateway will automatically restart and automatically navigate to the newly created Agent.
- Fixed the issue where an error was reported when generating an Agent ID from a name containing Chinese characters.
- Fixed file permission issues when accessing a shared Vault.
- Several other improvements.


## [1.8.0] - 2026-04-12

### Features
- Secure Vault: each Shrimp gets an isolated file space; data is invisible between Shrimps; admins exchange files via Finder
- Public Folder: shared resource space across all Shrimps for prompt templates, reference data, etc.
- Channel binding management: visual channel binding status with Feishu/WeChat configuration support
- Channel pairing UX: pairing completion now keeps the config panel open instead of auto-closing
- ClawdHome CLI: new command-line tool for scripted management
- Offline config writes: config changes fall back to local file writes when the Gateway is offline
- Upgrade UX: upgrade animations, in-card upgrade entry, and app update banner

### Improvements & Fixes
- XPC terminal output switched to Data transport, fixing ANSI/UTF-8 truncation garbling
- Extracted UserEnvContract for unified user isolation environment variables
- Version label distinguishes loading vs loaded states, eliminating flicker
- Skills install shows recovery message when exit code is non-zero but verification passes
- Backup list queries now include diagnostic logging
- Environment validation fixes, deeper diagnostics checks, and recovery progress overlay
- Process table column widths optimized


## [1.7.0] - 2026-04-09

### Features
- Hierarchical backup & restore: back up individual Shrimps or all at once, restore to any snapshot
- Appearance mode: cycle between System, Light, and Dark themes
- Cron task manager: visual UI for scheduled tasks with execution logs
- Skills Store: browse, install, configure, and manage OpenClaw skills
- Model priority management: drag-to-reorder fallback chains for model selection
- Diagnostics center: one-stop health checks across environment, permissions, config, security, Gateway, and network
- Hot config reload: apply configuration changes without restarting the Gateway
- Ed25519 device identity for enhanced WebSocket authentication
- Helper health panel: view Helper status in Settings with force-restart capability
- Memory log sidebar: browse and manage Shrimp memory logs
- Setup wizard fetches model lists from custom provider APIs

### Improvements & Fixes
- XPC calls now enforce timeouts, preventing UI freezes when the Helper is unresponsive
- Watchdog uses smart retry intervals and skips uninstalled users
- Node.js installation validated with SHA-256 checksums; Zip Slip and npm injection defenses added
- Backup performance improved by replacing double-tar with rsync
- Backup directory moved to a user-accessible location
- Fixed username parsing for backup filenames containing hyphens
- Fixed Cron/Skills API failures caused by cleared scope
- Fixed incorrect slash escaping in JSON config files
- Web UI now shows loading indicators
- Process table streamlined; files open in editor on double-click
- Floating banner warns when Helper connection is lost
- Auto-recovery after disconnection during upgrades
- Admin users can see upgradable Shrimp count


## [1.6.0] - 2026-04-03

### Features
- Added Node toolchain diagnosis with one-click repair to quickly troubleshoot and fix gateway runtime issues

### Improvements & Fixes
- Improved app update check and upgrade progress UX


## [1.5.0] - 2026-04-02

### Features
- Added a setup wizard to guide first-time Shrimp initialization
- App update checks now run in the background for improved reliability

### Improvements & Fixes
- Refined detail window layout and overview interaction experience
- Improved upgrade notification messages
- Hardened proxy configuration and permission checks
- Improved stability of isolation environments and the initialization flow


## [1.4.0] - 2026-03-31

### Features
- Proxy settings are now automatically applied to managed users
- Added authentication assist for terminal-based flows
- Expanded role presets in the Role Center with full localization

### Improvements & Fixes
- Streamlined user onboarding with a clearer step-by-step flow
- Improved in-app update and model configuration experiences
- Universal packaging now supports both Intel and Apple Silicon
- App notarization enabled by default for improved macOS trust


## [1.3.0] - 2026-03-29

### Features
- Added Role Market for browsing and adopting preconfigured role setups
- Direct model configuration without requiring a preset
- Redesigned onboarding experience with support for cloning from existing Shrimps
- Gateway watchdog: automatically monitors and recovers crashed gateway instances

### Improvements & Fixes
- Polished onboarding and user management interaction details
- Improved in-app banner notifications
- Safer handling of user directory ownership and permissions
- Refined quick-transfer copy


## [1.2.0] - 2026-03-26

### Features
- **WeChat onboarding**: Added a guided onboarding flow for WeChat-channel Shrimps to streamline initial setup.
- **Quick file transfer in detail view**: Upload and download files directly from the Shrimp detail panel — no need to open the full file manager.
- **Terminal opens at current path**: When launching a terminal from the file manager's maintenance window, the session starts in the directory you're already browsing.
- **Model status quick command**: A new shortcut command lets you instantly check the running status of model services from the management UI.

### Improvements & Fixes
- **Init wizard stability**: Fixed intermittent freezes and unexpected navigation jumps during the Shrimp initialization flow for a smoother setup experience.
- **Homebrew permission auto-repair**: The app now detects and attempts to automatically fix Homebrew permission issues, reducing the need for manual troubleshooting.
- **Localized model labels**: Fallback model display names are now fully translated and no longer appear as raw English identifiers.
- **Log output improvements**: Refined logging behavior to produce cleaner, less noisy output.