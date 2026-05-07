# Release Automation

This repository uses GitHub Actions for a standardized desktop packaging pipeline.

## Workflows

### 1. CI

File: `.github/workflows/ci.yml`

Runs on:

- push to `main`
- pull requests targeting `main`

Checks:

- `npm test`
- `npm run build`
- `cargo check`

Platforms:

- macOS
- Windows
- Ubuntu

### 2. Package Bundles

File: `.github/workflows/build.yml`

Runs on:

- `workflow_dispatch`

Purpose:

- build desktop installers without creating a GitHub Release
- upload the generated bundles as workflow artifacts

Supported targets:

- `macos-aarch64`
- `macos-x64`
- `windows-x64`
- `linux-x64`
- `all`

Usage:

1. Open GitHub Actions
2. Select `Package Bundles`
3. Choose a target set
4. Run the workflow
5. Download artifacts from the workflow run

### 3. Release

File: `.github/workflows/release.yml`

Runs on:

- push of tags matching `v*`

Purpose:

- build signed or unsigned production bundles
- publish them to GitHub Releases

Usage:

```bash
git tag v0.3.2
git push origin v0.3.2
```

## Versioning Rules

Keep these versions aligned before creating a release tag:

- `package.json`
- `../runtime/Cargo.toml`
- Git tag name, for example `v0.3.2`

Recommended order:

1. update the app version in source files
2. merge to `main`
3. create and push a version tag
4. verify the Release workflow assets

## Toolchain Baseline

- Node.js: `20`
- Rust: `1.91.0`

The repository pins Rust with `rust-toolchain.toml` so local development and GitHub Actions use the same compiler baseline.

## Secrets

### Required

- no custom secret is required for unsigned Windows and Linux packaging
- `GITHUB_TOKEN` is provided automatically by GitHub Actions

### Optional macOS signing and notarization

If you want signed macOS bundles, configure:

- `APPLE_CERTIFICATE`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_PASSWORD`
- `APPLE_TEAM_ID`

If these secrets are absent, macOS bundles can still be built, but signing and notarization will not run.

## Local Commands

```bash
npm test
npm run build
npm run check:rust
npm run package:desktop
```

## Notes

- the manual package workflow is for internal verification and artifact download
- the release workflow is the only path that should create GitHub Releases
- avoid releasing from arbitrary branch names; release only from version tags
- keep the branch clean before tagging
