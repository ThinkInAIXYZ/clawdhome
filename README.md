# ClawdHome

English | [中文](README.zh.md)

**ClawdHome securely isolates and operates multiple OpenClaw gateway instances on a single Mac.**

ClawdHome is built for \"raising Shrimps\" on your Mac: each Shrimp should live in a safe, reliable house with clear boundaries.

## Website & Download

- [https://clawdhome.app](https://clawdhome.app)

## Who It Is For

ClawdHome is designed for makers and operators who want to run multiple OpenClaw gateways on one Mac without mixing identities, data, and permissions. It is especially useful when you need production/staging isolation, low-risk clone-and-test workflows, and a single operations UI for day-to-day maintenance.

## Visual Overview

<table>
  <tr>
    <td><img src="docs/assets/readme/github-dashboard.png" alt="Dashboard" /></td>
    <td><img src="docs/assets/readme/github-claw-pool.png" alt="Claw Pool" /></td>
  </tr>
  <tr>
    <td><img src="docs/assets/readme/github-filemanager.png" alt="File Manager" /></td>
    <td><img src="docs/assets/readme/github-process.png" alt="Process" /></td>
  </tr>
</table>

ClawdHome provides a single control plane to monitor, isolate, and operate multiple OpenClaw gateway instances for different people and roles.

## What ClawdHome Is

ClawdHome is a macOS control-plane app for securely isolating and operating multiple OpenClaw gateway instances, with a privileged helper daemon for system-level operations. It focuses on one thing: safely running and managing multiple isolated OpenClaw gateway instances on one machine. Each "Shrimp" runs in its own boundary with separate runtime context, data, and policy.

## Why It Exists

- OpenClaw is not a one-time setup; it needs continuous \"raising\" (learning, growth, iteration). That requires each Shrimp to have its own house: account isolation and permission boundaries.
- Raising also needs low-risk iteration: you should be able to quickly clone a Shrimp for experiments, rehearsals, and regression checks, then shape a stable, maintainable digital twin.
- A primary MacBook should also run Shrimps safely with low overhead: humans on admin accounts, Shrimps on standard accounts, each Shrimp in its own boundary.
- Virtual machines and Docker are often too heavy for this use case; macOS multi-user primitives provide a more native path (system UI and browser automation).
- Raising Shrimps is not only about chat; Shrimps should connect to smart-home workflows and leverage Mac neural/GPU acceleration for lower-latency, lower-cost local capabilities.
- OpenClaw instances can fail in real-world use, so centralized operations plus backup, maintenance, and recovery workflows are essential.

## How It Works

```
ClawdHome.app (admin UI)
  -> XPC -> ClawdHomeHelper (privileged daemon)
      -> user-level OpenClaw gateway instances (isolated per Shrimp)
```

- `ClawdHome.app` provides UI for operations, status, and configuration.
- `ClawdHomeHelper` performs privileged system actions via controlled interfaces.
- Each Shrimp maps to an isolated OpenClaw gateway runtime.
- Gateway lifecycle is managed per instance (start/stop/restart/health checks).
- Per-instance config and data are handled with explicit ownership and permission logic.

## Security Model

- Privileged operations are isolated in the helper daemon boundary.
- User-scoped runtime resources are separated per Shrimp/gateway instance.
- Sensitive operations are routed through explicit XPC methods, not ad-hoc shell paths.
- Ownership and permission repair is built into key lifecycle workflows.

## Quick Start

### Requirements

- macOS 14+
- Xcode 15+
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Build and run

```bash
open ClawdHome.xcodeproj
```

Or regenerate first:

```bash
xcodegen generate
open ClawdHome.xcodeproj
```

### Install helper (development)

```bash
make install-helper
```

Equivalent direct command:

```bash
sudo bash scripts/install-helper-dev.sh install
```

### Troubleshooting npm install on macOS

If OpenClaw installation fails during `npm install -g`, check Xcode CLI prerequisites first:

```bash
xcode-select -p
```

If the command fails, install Command Line Tools:

```bash
xcode-select --install
```

If you see a license-related error, accept it as admin:

```bash
sudo xcodebuild -license
# or non-interactive:
sudo xcodebuild -license accept
```

## Key Capabilities

- Multi-Shrimp OpenClaw gateway isolation on one Mac.
- Per-instance lifecycle control and health visibility.
- Managed user operations and bootstrap workflows.
- Config editing and diagnostics tooling in one UI.
- File, session, memory, and log management surfaces.
- Local AI operational integration (where configured).

## Repository Layout

```text
ClawdHome/
  UI app (SwiftUI), models, services, views
ClawdHomeHelper/
  privileged helper daemon and operations
Shared/
  shared protocol/models between app and helper
scripts/
  build, install, packaging, release-note utilities
Resources/
  helper launch daemon plist and packaging resources
```

## Development Workflow

- Build app debug:

```bash
make build
```

- Build helper debug:

```bash
make build-helper
```

- Build pkg:

```bash
make pkg
```

- Show helper logs:

```bash
make log-helper
```

## Roadmap

- [ ] External key management (Exec-based secrets provider).
- [ ] Fine-grained network access control management.
- [ ] Simplified configuration for more model providers and IM channels.
- [ ] Local small-model integrated runtime, scenario skills, and OpenClaw integration.
- [ ] Rescue and diagnostics capabilities.
- [ ] Improved gateway probing and historical health tracking.
- [ ] Production-grade signed/notarized distribution pipeline.

## Contributing

- Open an issue first for major changes.
- Keep PRs scoped and atomic.
- Include validation evidence for behavior changes.
- Avoid committing local/private environment artifacts.
- Follow existing Swift style and project structure.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).
