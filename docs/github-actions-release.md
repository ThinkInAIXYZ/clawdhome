# GitHub Actions 发布流程

ClawdHome 的 GitHub Actions 发布流程分两段：

1. `Draft Release Notes`：生成 `release-notes/vX.Y.Z.zh.md` 和 `release-notes/vX.Y.Z.en.md`，并创建 PR。
2. `Release`：在 release notes PR 合并后，构建、签名、公证并发布 GitHub Release。

这样 release notes 的人工确认发生在 PR review 阶段，Actions 不需要中途等待人工输入。

## 首次配置

在 GitHub 仓库中配置 `Settings -> Secrets and variables -> Actions`：

必需 secrets：

- `APPLE_TEAM_ID`
- `APP_SIGN_IDENTITY`
- `PKG_SIGN_IDENTITY`
- `APP_CERT_P12_BASE64`
- `APP_CERT_PASSWORD`
- `PKG_CERT_P12_BASE64`
- `PKG_CERT_PASSWORD`
- `KEYCHAIN_PASSWORD`

公证 credentials 二选一：

- App Store Connect API key：
  - `ASC_KEY_P8_BASE64`
  - `ASC_KEY_ID`
  - `ASC_ISSUER_ID`
- Apple ID app-specific password：
  - `NOTARY_APPLE_ID`
  - `NOTARY_APP_SPECIFIC_PASSWORD`

可选 secrets：

- `RELEASE_BOT_TOKEN`：如果主仓库分支保护不允许 `GITHUB_TOKEN` push release commit/tag，配置一个有写权限的 PAT。
- `WEBSITE_REPO_TOKEN`：如果需要由 workflow 给网站仓库创建 changelog/download PR，配置一个对网站仓库有写权限的 PAT。

可选 variables：

- `WEBSITE_REPO`：默认是 `deepjerry-ai/clawdhome_website`。

建议配置 GitHub Environment：

- 新建 environment：`APPLE_TEAM_ID`
- 给 environment 增加 required reviewers

`Release` workflow 已绑定 `environment: APPLE_TEAM_ID`。这样正式发布前 GitHub 会要求人工批准。

`Release` workflow 使用 `macos-26` runner，并在构建前输出 `xcodebuild -version`，确保正式发布使用 GitHub macOS 26 镜像提供的 Xcode 26 工具链。

## 证书和密钥准备

从 Keychain Access 导出两个 `.p12`：

- Developer ID Application 证书，对应 `APP_SIGN_IDENTITY`
- Developer ID Installer 证书，对应 `PKG_SIGN_IDENTITY`

转成 GitHub secret：

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
base64 -i DeveloperIDInstaller.p12 | pbcopy
```

从 App Store Connect 下载 notary API key `.p8` 后转成 GitHub secret：

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

如果沿用本机 `clawdhome-release` 的旧方式，则不需要 `ASC_KEY_*`。改为配置：

- `NOTARY_APPLE_ID`：创建 notary profile 时使用的 Apple ID
- `NOTARY_APP_SPECIFIC_PASSWORD`：Apple ID 的 app 专用密码

对应命令等价于：

```bash
xcrun notarytool store-credentials clawdhome-release \
  --apple-id "$NOTARY_APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$NOTARY_APP_SPECIFIC_PASSWORD"
```

Apple 的 app 专用密码只在创建时显示一次。如果已经忘记且 Apple ID 账号无法登录，就不能为 GitHub Actions 重新创建 notary profile；这时只能继续在已有 `clawdhome-release` profile 的本机上完成公证，或先恢复 Apple ID 账号访问。

`KEYCHAIN_PASSWORD` 可以是一个专用于 CI 临时 keychain 的随机长密码，不需要等于 macOS 登录密码。

## 正常发布

1. 打开 GitHub `Actions -> Draft Release Notes`。
2. 点击 `Run workflow`，通常不填 `version`。
3. 等 workflow 创建 release notes PR。
4. 在 PR 中编辑并确认：
   - `release-notes/vX.Y.Z.zh.md`
   - `release-notes/vX.Y.Z.en.md`
5. 合并 PR。
6. 打开 `Actions -> Release`。
7. 点击 `Run workflow`。
8. 保持 `notarize=true`。
9. 如果要同步网站仓库，勾选 `publish_website=true`。

发布 workflow 会执行：

```bash
make test-release-scripts
make release-prepare
make release-build
make release-publish
```

## 修小 bug 但 release notes 不变

先确认当前下一版本号：

```bash
bash scripts/semver.sh
```

如果版本号仍然是已确认 notes 对应的版本，直接提交 bug fix，然后运行 `Release` workflow。

如果版本号变化了，只改文件名，不改内容：

```bash
make notes-rename FROM=1.11.2 TO=1.11.3
```

提交重命名后再运行 `Release` workflow。正式发布 workflow 会检查当前 `scripts/semver.sh` 结果对应的中英文 notes 是否存在，避免误用旧版本 notes。

## 网站发布

`publish_website=true` 时，workflow 会 checkout 网站仓库到 `_website`，调用现有 `release_publish.sh` 创建网站 changelog/download PR。

由于网站 PR 合并和部署通常发生在主 app release 之后，CI 中会设置：

```bash
SKIP_ONLINE_VERIFY=true
```

这只跳过 `clawdhome.app` 线上 URL 即时校验，不影响 GitHub Release、签名、公证或 website PR 创建。
