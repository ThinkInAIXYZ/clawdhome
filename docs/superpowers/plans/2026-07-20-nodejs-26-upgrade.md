# Node.js 26 Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 ClawdHome 内置 Node.js 固定升级为 `v26.5.0`，并让浏览器 npm 包装器自动发现隔离用户实际安装的 Node.js 目录。

**Architecture:** `NodeDownloader` 继续作为唯一的内置版本与下载入口；`IsolatedNodeToolLookup` 继续作为隔离 Node 工具候选路径的共享生成器。`BrowserAccountManager` 从文件系统读取 `~/.brew/lib/nodejs` 实际目录并复用共享生成器，不再维护具体 Node.js 版本路径。

**Tech Stack:** Swift 5.9、Foundation、独立 `swiftc` 回归测试、XcodeGen/Xcode 工程、Make

## Global Constraints

- 内置 Node.js 版本固定为 `v26.5.0`，不在运行时查询 `latest`。
- 保留现有 Node.js 下载源、SHA-256 校验、缓存和安装目录行为。
- 不主动升级、删除或清理已有 Shrimp 用户的 Node.js 安装。
- 不修改 XPC 接口和本地化字符串。
- 保持 Apple Silicon `darwin-arm64` 与 Intel `darwin-x64` 支持。

---

### Task 1: Node 26 隔离工具候选策略

**Files:**
- Modify: `tests/IsolatedNodeToolLookupTests.swift`
- Modify: `Shared/HelperSharedTypes.swift:263`

**Interfaces:**
- Consumes: `IsolatedNodeToolLookup.candidateBinaryPaths(brewRoot:executableName:cellarFormulaVersions:libNodeEntries:) -> [String]`
- Produces: 包含 `opt/node@26` 和任意实际 `lib/nodejs/node-*` 目录的有序候选列表。

- [ ] **Step 1: 写入 Node 26 失败测试**

将测试输入升级为 Node 26，并增加 `node@26` 版本化 Homebrew 路径断言：

```swift
let candidates = IsolatedNodeToolLookup.candidateBinaryPaths(
    brewRoot: "/Users/intel_agent/.brew",
    executableName: "npm",
    cellarFormulaVersions: ["node": ["26.5.0"]],
    libNodeEntries: ["node-v26.5.0-darwin-arm64", "not-node"]
)

expect(
    candidates.contains("/Users/intel_agent/.brew/opt/node@26/bin/npm"),
    "npm lookup should include the Node.js 26 Homebrew opt candidate"
)
expect(
    candidates.contains("/Users/intel_agent/.brew/lib/nodejs/node-v26.5.0-darwin-arm64/bin/npm"),
    "npm lookup should include Node.js 26 lib/nodejs candidates"
)
```

- [ ] **Step 2: 运行测试并确认预期失败**

Run:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/clawdhome-clang-cache \
  SWIFT_MODULECACHE_PATH=/tmp/clawdhome-swift-cache \
  swiftc Shared/HelperSharedTypes.swift tests/IsolatedNodeToolLookupTests.swift \
  -o /tmp/isolated-node-tool-lookup-tests && \
  /tmp/isolated-node-tool-lookup-tests
```

Expected: FAIL，输出 `npm lookup should include the Node.js 26 Homebrew opt candidate`。

- [ ] **Step 3: 添加 Node 26 Homebrew 候选**

在稳定入口之后加入 Node 26：

```swift
var candidates = [
    "\(brewRoot)/bin/\(executableName)",
    "\(brewRoot)/opt/node/bin/\(executableName)",
    "\(brewRoot)/opt/node@26/bin/\(executableName)",
    "\(brewRoot)/opt/node@24/bin/\(executableName)",
    "\(brewRoot)/opt/node@22/bin/\(executableName)",
    "\(brewRoot)/opt/node@20/bin/\(executableName)",
    "\(brewRoot)/opt/node@18/bin/\(executableName)",
]
```

- [ ] **Step 4: 运行测试并确认通过**

Run: 与 Step 2 相同。

Expected: PASS，输出 `Isolated node tool lookup tests passed.`。

---

### Task 2: 固定内置版本并移除浏览器 npm 版本硬编码

**Files:**
- Modify: `ClawdHomeHelper/Operations/NodeDownloader.swift:11`
- Modify: `ClawdHomeHelper/Operations/BrowserAccountManager.swift:1520`

**Interfaces:**
- Consumes: Task 1 的 `IsolatedNodeToolLookup.candidateBinaryPaths(...)`。
- Produces: `NodeDownloader.nodeVersion == "v26.5.0"`；浏览器 npm 包装器按实际目录发现 npm。

- [ ] **Step 1: 更新固定下载版本**

```swift
static let nodeVersion = "v26.5.0"
```

同时将 `resolveExtractedDir` 注释示例更新为 `node-v26.5.0-darwin-arm64` 与 `node-26.5.0-darwin-arm64`，避免文档继续暗示旧内置版本。

- [ ] **Step 2: 用共享候选生成器替换硬编码 npm 路径**

在 `installNPMWrapperIfPossible` 中使用以下逻辑：

```swift
let brewRoot = "/Users/\(username)/.brew"
let libNodeRoot = "\(brewRoot)/lib/nodejs"
let libNodeEntries = (try? fm.contentsOfDirectory(atPath: libNodeRoot)) ?? []
let realCandidates = IsolatedNodeToolLookup.candidateBinaryPaths(
    brewRoot: brewRoot,
    executableName: "npm",
    cellarFormulaVersions: [:],
    libNodeEntries: libNodeEntries
) + [
    "/opt/homebrew/bin/npm",
    "/usr/local/bin/npm",
]
```

保留现有 `candidate != wrapperPath && fm.isExecutableFile(atPath: candidate)` 筛选条件。

- [ ] **Step 3: 检查旧版本硬编码已经移除**

Run:

```bash
rg -n "node-v24\.9\.0|node-v22\.18\.0|node-v20\.19\.0|node-v18\.20\.8" \
  ClawdHomeHelper/Operations/BrowserAccountManager.swift
```

Expected: 无输出，退出码为 1。

- [ ] **Step 4: 重新运行隔离工具回归测试**

Run: Task 1 Step 2 的测试命令。

Expected: PASS。

---

### Task 3: 全量构建验证

**Files:**
- Verify only: `ClawdHomeHelper/Operations/NodeDownloader.swift`
- Verify only: `ClawdHomeHelper/Operations/BrowserAccountManager.swift`
- Verify only: `Shared/HelperSharedTypes.swift`
- Verify only: `tests/IsolatedNodeToolLookupTests.swift`

**Interfaces:**
- Consumes: Task 1 与 Task 2 的最终实现。
- Produces: 可编译的 ClawdHome App 与 Helper。

- [ ] **Step 1: 检查补丁格式与范围**

Run:

```bash
git diff --check -- \
  ClawdHomeHelper/Operations/NodeDownloader.swift \
  ClawdHomeHelper/Operations/BrowserAccountManager.swift \
  Shared/HelperSharedTypes.swift \
  tests/IsolatedNodeToolLookupTests.swift
```

Expected: 无输出，退出码为 0。

- [ ] **Step 2: 构建 App 与 Helper**

Run:

```bash
make build
```

Expected: `BUILD SUCCEEDED`，App 与 Helper 均编译成功。

- [ ] **Step 3: 审阅最终差异**

Run:

```bash
git diff -- \
  ClawdHomeHelper/Operations/NodeDownloader.swift \
  ClawdHomeHelper/Operations/BrowserAccountManager.swift \
  Shared/HelperSharedTypes.swift \
  tests/IsolatedNodeToolLookupTests.swift
```

Expected: 仅包含 Node.js 26 版本、通用 npm 发现与对应测试变更。

- [ ] **Step 4: 提交实现**

```bash
git add \
  ClawdHomeHelper/Operations/NodeDownloader.swift \
  ClawdHomeHelper/Operations/BrowserAccountManager.swift \
  Shared/HelperSharedTypes.swift \
  tests/IsolatedNodeToolLookupTests.swift
git commit -m "feat: upgrade bundled Node.js to 26.5.0"
```
