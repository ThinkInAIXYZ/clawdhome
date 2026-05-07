# ClawdHome

[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://clawdhome.app)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://developer.apple.com/swift/)
[![License](https://img.shields.io/github/license/ThinkInAIXYZ/clawdhome)](LICENSE)
[![Release](https://img.shields.io/github/v/release/ThinkInAIXYZ/clawdhome)](https://github.com/ThinkInAIXYZ/clawdhome/releases)

English | [中文](README.zh.md)

> Native macOS control plane for securely running and managing multiple isolated OpenClaw gateway instances on a single Mac.

ClawdHome is built for people who want one machine to host multiple OpenClaw "Shrimps" without mixing identities, data, permissions, or operational risk. It combines a SwiftUI admin app, a privileged XPC helper daemon, and macOS multi-user isolation into a single workflow for setup, monitoring, cloning, maintenance, and recovery.

Website: [clawdhome.app](https://clawdhome.app)  
Downloads: [GitHub Releases](https://github.com/ThinkInAIXYZ/clawdhome/releases)  
Changelog: [English](CHANGELOG.en.md) | [中文](CHANGELOG.zh.md)

## Community Groups

<table>
  <tr>
    <td align="center">
      <img src="docs/assets/readme/feishu-group.png" alt="Feishu Group QR Code" width="220" />
      <br />
      Feishu Group
    </td>
    <td align="center">
      <img src="docs/assets/readme/wechat-group.png" alt="WeChat Group QR Code" width="220" />
      <br />
      WeChat Group
    </td>
  </tr>
</table>

## Screenshots

<table>
  <tr>
    <td><img src="docs/assets/readme/github-dashboard.png" alt="Dashboard" /></td>
    <td><img src="docs/assets/readme/github-claw-pool.png" alt="Claw Pool" /></td>
  </tr>
  <tr>
      <td><img src="docs/assets/readme/github-role-center.png" alt="Role Center" /></td>
      <td><img src="docs/assets/readme/github-role-awaken.png" alt="Role Awaken" /></td>
  </tr>
</table>

## Why ClawdHome

- Real isolation: each Shrimp maps to its own macOS user account, runtime context, data, and permission boundary.
- Safer privilege model: system-level actions are routed through an explicit XPC helper instead of ad-hoc shell flows inside the UI app.
- Faster iteration: clone an existing Shrimp for experiments, rehearsal, or regression checks, then promote what works.
- Native Mac fit: uses macOS user and process primitives instead of heavier VM or container workflows for this class of desktop automation.
- Unified operations: manage onboarding, gateway lifecycle, files, logs, processes, config, and diagnostics from one place.

## Highlights

- Run multiple OpenClaw gateway instances on one Mac with clear per-instance boundaries.
- Guided onboarding for new Shrimps, including channel-specific setup flows such as WeChat pairing.
- Clone an existing Shrimp into a new isolated account for low-risk testing and rollout rehearsal.
- Gateway lifecycle management with health visibility and watchdog-based recovery.
- Built-in tools for files, sessions, processes, logs, and maintenance operations.
- Model and provider configuration from the app, including direct model setup and Role Market-based presets.
- Local AI operations support, including integration hooks for local model services where configured.
- English and Chinese localization based on `Stable.xcstrings`.

## Architecture

```text
ClawdHome.app (SwiftUI admin UI)
  -> XPC -> ClawdHomeHelper (privileged LaunchDaemon)
      -> per-user OpenClaw gateway instances
```

- `ClawdHome.app` is the operator-facing control plane for status, setup, and day-to-day maintenance.
- `ClawdHomeHelper` is the privileged boundary for user management, process control, file operations, installs, and system automation.
- Each Shrimp runs as a separate macOS user with its own OpenClaw runtime and data.

## Security Model

- Privileged operations stay inside the helper boundary.
- Sensitive actions use explicit XPC methods rather than arbitrary shell paths.
- Ownership and permission repair are built into important lifecycle workflows.
- Runtime resources are separated per Shrimp to reduce blast radius and accidental cross-contamination.

## Quick Start

### Requirements

- macOS 14+
- Xcode 15+
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Build From Source

```bash
open ClawdHome.xcodeproj
```

If you prefer to regenerate the Xcode project first:

```bash
xcodegen generate
open ClawdHome.xcodeproj
```

### Install Helper For Local Development

```bash
make install-helper
```

Equivalent direct command:

```bash
sudo bash scripts/install-helper-dev.sh install
```

## Common Commands

| Purpose | Command |
| --- | --- |
| Build app (Debug) | `make build` |
| Build helper only | `make build-helper` |
| Build release archive | `make build-release` |
| Build unsigned local package | `make pkg` |
| Build signed package for local validation | `make pkg-signed` |
| Build signed and notarized package | `make notarize-pkg` |
| Run full release flow | `make release NOTARIZE=true` |
| Run exported Release app directly | `make run-release` |
| Install latest generated package | `make install-pkg` |
| Uninstall development helper | `make uninstall-helper` |
| Tail helper logs | `make log-helper` |
| Tail app logs | `make log-app` |
| Run localization checks | `make i18n-check` |
| Clean build artifacts | `make clean` |

## Troubleshooting

### `npm install -g` fails on macOS

Check whether Xcode Command Line Tools are available:

```bash
xcode-select -p
```

If the command fails, install them:

```bash
xcode-select --install
```

If you hit an Xcode license error, accept it as an admin user:

```bash
sudo xcodebuild -license
# or non-interactive:
sudo xcodebuild -license accept
```

### Where to look for logs

- Helper log: `/tmp/clawdhome-helper.log`
- App log stream: `make log-app`

## Repository Layout

```text
ClawdHome/          SwiftUI app, views, models, services
ClawdHomeHelper/    privileged helper daemon and operations
Shared/             protocols and shared models for app/helper
Resources/          launch daemon plist and packaging resources
scripts/            build, install, packaging, release, and i18n utilities
docs/               project documentation and README assets
release-notes/      generated release-note drafts
```

## Localization

- Languages: English and Chinese
- String system: `Stable.xcstrings`
- Checks: `make i18n-check`
- Guide: [docs/i18n.md](docs/i18n.md)

## Roadmap

- [ ] External key management with an exec-based secrets provider
- [ ] Finer-grained network access control management
- [ ] Simpler setup for more model providers and IM channels
- [ ] Better local small-model workflows and OpenClaw integration
- [ ] Stronger rescue and diagnostics capabilities
- [ ] Better gateway probing and historical health tracking
- [ ] More production-ready signed and notarized distribution workflows

## Contributing

- Open an issue before large or structural changes.
- Keep pull requests small, focused, and easy to review.
- Include validation evidence for behavior changes.
- Avoid committing local or private environment artifacts.
- Follow the existing Swift and project structure conventions.
- The repository currently does not ship automated unit tests, so manual verification notes are especially important in PRs.

## Star History

<a href="https://www.star-history.com/?repos=ThinkInAIXYZ%2Fclawdhome&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/image?repos=ThinkInAIXYZ/clawdhome&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/image?repos=ThinkInAIXYZ/clawdhome&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/image?repos=ThinkInAIXYZ/clawdhome&type=date&legend=top-left" />
 </picture>
</a>

## License

Apache License 2.0. See [LICENSE](LICENSE).
