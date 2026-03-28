# Changelog

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