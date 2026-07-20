# 内置 Node.js 26 升级设计

## 背景

ClawdHome Helper 当前固定下载并安装 Node.js `v24.9.0`。项目需要将内置版本升级为 Node.js 官方当前最新版本 `v26.5.0`。浏览器工具的 npm 包装器还包含多个具体 Node.js 版本目录，若只修改下载器版本，可能在稳定符号链接缺失时无法找到新版 npm。

## 目标

- 将项目内置 Node.js 固定版本升级为 `v26.5.0`。
- 保留现有官方源、镜像源、SHA-256 校验、缓存及安装目录行为。
- 移除浏览器工具对具体 Node.js 安装版本的依赖，使后续版本升级无需同步修改 npm 回退路径。
- 不主动升级或删除现有 Shrimp 用户已经安装的 Node.js；新安装或明确执行修复安装时使用新版本。

## 非目标

- 不在运行时查询或自动追踪 Node.js `latest`。
- 不增加 Node.js 版本选择界面。
- 不改变 Node.js 下载源配置或已有 XPC 接口。
- 不清理用户目录中的旧 Node.js 解压目录。

## 方案

### 固定安装版本

将 `NodeDownloader.nodeVersion` 从 `v24.9.0` 更新为 `v26.5.0`。下载文件名、SHASUMS URL、缓存名称、解压目录解析及符号链接目标继续由该常量生成。

固定版本保证安装结果可复现，也避免镜像同步延迟或上游新版本发布导致未经验证的行为变化。

### 通用 npm 路径发现

`BrowserAccountManager.installNPMWrapperIfPossible` 不再维护 `node-v24.9.0`、`node-v22.18.0` 等具体路径。它读取目标用户 `~/.brew/lib/nodejs` 下的实际目录项，并复用 `IsolatedNodeToolLookup.candidateBinaryPaths` 生成候选路径。

候选顺序保持以下原则：

1. 优先使用稳定入口 `~/.brew/bin/npm`。
2. 其次使用 `~/.brew/opt` 中的 Node.js npm。
3. 再从 `~/.brew/lib/nodejs/node-*` 实际安装目录中寻找 npm。
4. 最后回退到系统 Homebrew npm 路径。

浏览器 npm 包装器只选择真实存在且可执行、并且不等于包装器自身路径的候选项。

## 错误处理与兼容性

- `~/.brew/lib/nodejs` 不存在或无法读取时按空目录处理，继续检查稳定入口和系统路径。
- 新版本下载仍必须通过对应发布目录的 `SHASUMS256.txt` 校验。
- Apple Silicon 和 Intel Mac 继续分别使用 `darwin-arm64` 与 `darwin-x64` 官方压缩包。
- 现有 `v24`、`v22` 等目录仍可被通用发现逻辑识别，不影响旧安装。

## 测试与验证

- 先增加回归测试，证明通用候选生成能发现 `node-v26.5.0-darwin-arm64/bin/npm`，并保持稳定符号链接优先。
- 验证旧版具体路径不再出现在 `BrowserAccountManager` 中。
- 运行相关 Swift 测试。
- 运行 `make build`，确认 App 与 Helper 均能编译。
- 本次不新增或修改本地化字符串，因此无需改动 `Stable.xcstrings`。
