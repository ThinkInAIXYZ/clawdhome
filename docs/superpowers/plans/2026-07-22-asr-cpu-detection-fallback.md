# ASR CPU 架构判定降级 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 ASR CLI 在受限环境无法读取硬件 sysctl 时，仍能正确放行原生 Apple Silicon 进程，同时不放行 Intel Mac。

**Architecture:** 新增独立的 `ASRPlatformDetector`，把环境覆盖、硬件级 sysctl、进程级 `uname` 判定收敛为三个显式结果。`ASRCommand` 只消费结果并决定用户可见错误，测试通过独立 Swift 可执行文件注入所有检测输入而不依赖当前机器。

**Tech Stack:** Swift 5.9、Foundation、Darwin、Bash、xcrun swiftc。

---

### Task 1: 建立可注入的架构判定回归测试

**Files:**
- Create: `tests/ASRPlatformDetectorTests.swift`
- Create: `tests/ASRPlatformDetectorTests.sh`
- Modify: `scripts/test-cli.sh:10-16`

- [ ] **Step 1: 新增先失败的 Swift 判定测试**

创建 `tests/ASRPlatformDetectorTests.swift`：

```swift
import Foundation

@main
struct ASRPlatformDetectorTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        expect(
            ASRPlatformDetector.detect(
                override: "arm64",
                hardwareARM64: 0,
                processArchitecture: "x86_64"
            ) == .appleSilicon,
            "arm64 override must take priority for tests"
        )
        expect(
            ASRPlatformDetector.detect(
                override: nil,
                hardwareARM64: 1,
                processArchitecture: "x86_64"
            ) == .appleSilicon,
            "hardware sysctl must identify Apple Silicon under Rosetta"
        )
        expect(
            ASRPlatformDetector.detect(
                override: nil,
                hardwareARM64: nil,
                processArchitecture: "arm64"
            ) == .appleSilicon,
            "native arm64 must be accepted when sysctl is denied"
        )
        expect(
            ASRPlatformDetector.detect(
                override: nil,
                hardwareARM64: nil,
                processArchitecture: "x86_64"
            ) == .intel,
            "x86_64 fallback must remain unsupported"
        )
        expect(
            ASRPlatformDetector.detect(
                override: nil,
                hardwareARM64: nil,
                processArchitecture: nil
            ) == .unknown,
            "unavailable hardware and process probes must be unknown"
        )
        print("ASR platform detector tests passed.")
    }
}
```

- [ ] **Step 2: 添加并运行失败测试脚本**

创建 `tests/ASRPlatformDetectorTests.sh`：

```bash
#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BIN="$(mktemp /tmp/clawdhome-asr-platform-tests.XXXXXX)"
trap 'rm -f "$TEST_BIN"' EXIT

/usr/bin/xcrun swiftc \
  "$REPO_ROOT/ClawdHomeCLI/ASRPlatformDetector.swift" \
  "$REPO_ROOT/tests/ASRPlatformDetectorTests.swift" \
  -o "$TEST_BIN"
"$TEST_BIN"
```

运行：`bash tests/ASRPlatformDetectorTests.sh`

预期：失败，提示 `ClawdHomeCLI/ASRPlatformDetector.swift` 尚不存在。

- [ ] **Step 3: 将独立测试接入既有 CLI 回归脚本**

在 `scripts/test-cli.sh` 的配置段后添加仓库根目录，并在 `section "1.1 AI 能力命令"` 后添加：

```bash
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
```

```bash
assert_ok "ASR CPU 架构降级判定" bash "$REPO_ROOT/tests/ASRPlatformDetectorTests.sh"
```

### Task 2: 实现分层判定并接入 CLI

**Files:**
- Create: `ClawdHomeCLI/ASRPlatformDetector.swift`
- Modify: `ClawdHomeCLI/Commands/AICommand.swift:357-372`
- Modify: `ClawdHome.xcodeproj/project.pbxproj` (由 XcodeGen 生成)
- Test: `tests/ASRPlatformDetectorTests.swift`

- [ ] **Step 1: 新增最小判定器实现**

创建 `ClawdHomeCLI/ASRPlatformDetector.swift`：

```swift
import Foundation
import Darwin

enum ASRPlatformDetector {
    enum Result: Equatable {
        case appleSilicon
        case intel
        case unknown
    }

    static func current() -> Result {
        detect(
            override: ProcessInfo.processInfo.environment["CLAWDHOME_CPU_ARCH_OVERRIDE"],
            hardwareARM64: hardwareARM64(),
            processArchitecture: processArchitecture()
        )
    }

    static func detect(
        override: String?,
        hardwareARM64: Int32?,
        processArchitecture: String?
    ) -> Result {
        if let override, !override.isEmpty {
            return override == "arm64" ? .appleSilicon : .intel
        }
        if let hardwareARM64 {
            return hardwareARM64 == 1 ? .appleSilicon : .intel
        }
        switch processArchitecture?.lowercased() {
        case "arm64", "arm64e":
            return .appleSilicon
        case "x86_64", "i386":
            return .intel
        default:
            return .unknown
        }
    }

    private static func hardwareARM64() -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }

    private static func processArchitecture() -> String? {
        var uts = utsname()
        guard uname(&uts) == 0 else { return nil }
        let capacity = MemoryLayout.size(ofValue: uts.machine)
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}
```

- [ ] **Step 2: 用判定结果替换 ASR 的布尔检查**

在 `ClawdHomeCLI/Commands/AICommand.swift` 中将原来的 `requireSupportedPlatform()` 和 `isAppleSilicon()` 替换为：

```swift
private static func requireSupportedPlatform() throws {
    switch ASRPlatformDetector.current() {
    case .appleSilicon:
        return
    case .intel:
        throw CLIError.operationFailed("ASR requires Apple Silicon. Intel Macs are not supported.")
    case .unknown:
        throw CLIError.operationFailed("无法确认当前环境的 CPU 架构。ASR requires Apple Silicon.")
    }
}
```

- [ ] **Step 3: 运行新测试验证实现**

运行：`bash tests/ASRPlatformDetectorTests.sh`

预期：输出 `ASR platform detector tests passed.`，退出码为 `0`。

- [ ] **Step 4: 重新生成 Xcode 工程，使 CLI target 编译新源文件**

```bash
xcodegen generate
git diff -- ClawdHome.xcodeproj/project.pbxproj
```

预期：生成后的 `project.pbxproj` 包含 `ASRPlatformDetector.swift`，且 XcodeGen 没有删除当前工作区已有的项目配置改动。

- [ ] **Step 5: 检查变更归属，不创建混合提交**

运行：`git status --short` 与 `git diff --check`

预期：新增的判定器与测试文件清晰可辨；`ClawdHomeCLI/Commands/AICommand.swift`、`scripts/test-cli.sh` 和 `project.pbxproj` 中的既有用户改动保持未被还原或整体暂存。由于这些文件在开始实施前已处于修改状态，本任务不创建可能包含无关内容的提交。

### Task 3: 构建与 CLI 回归验证

**Files:**
- Verify: `ClawdHomeCLI/ASRPlatformDetector.swift`
- Verify: `ClawdHomeCLI/Commands/AICommand.swift`
- Verify: `scripts/test-cli.sh`

- [ ] **Step 1: 编译 CLI**

运行：`make build-cli`

预期：输出 `BUILD SUCCEEDED`。

- [ ] **Step 2: 运行 ASR 架构判定测试**

运行：`bash tests/ASRPlatformDetectorTests.sh`

预期：输出 `ASR platform detector tests passed.`。

- [ ] **Step 3: 运行既有 CLI 集成回归**

运行：`make test-cli`

预期：ASR 段落中的 `ASR CPU 架构降级判定` 与 `Intel 上 ai asr 明确提示不支持` 均通过，脚本以 `0` 退出。
