// tests/ClawdHomeAppXCTests/ManagedUserStateTests.swift
// 核心主流程测试 — 单元测试：ManagedUser 状态与本地存储逻辑

import XCTest
import AppKit
@testable import ClawdHome

final class ManagedUserStateTests: XCTestCase {

    /// 测试 ManagedUser 实例化及其默认标识填充
    func testManagedUserInitialization() {
        // 1. macOS 用户默认标识填充
        let macUser = ManagedUser(username: "alice", fullName: "Alice Admin", isAdmin: true, clawType: .macosUser)
        XCTAssertEqual(macUser.username, "alice")
        XCTAssertEqual(macUser.fullName, "Alice Admin")
        XCTAssertTrue(macUser.isAdmin)
        XCTAssertEqual(macUser.identifier, "@alice")
        XCTAssertFalse(macUser.isRunning)
        XCTAssertFalse(macUser.isFrozen)

        // 2. Docker 用户默认标识填充
        let dockerUser = ManagedUser(username: "bob", fullName: "Bob Docker", clawType: .docker)
        XCTAssertEqual(dockerUser.identifier, L10n.k("models.managed_user.configuration", fallback: ":未配置"))

        // 3. 自定义标识
        let customSSH = ManagedUser(username: "pi", fullName: "Pi SSH", clawType: .ssh, identifier: "pi@192.168.1.100")
        XCTAssertEqual(customSSH.identifier, "pi@192.168.1.100")
    }

    /// 头像裁剪应使用底层位图坐标，避免 NSImage size 与 CGImage 像素尺寸不一致时保存失败
    func testAvatarCropUsesBitmapPixelBoundsWhenImageSizeDiffers() {
        let source = NSImage(size: NSSize(width: 100, height: 200))
        source.lockFocus()
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 100, height: 200)).fill()
        source.unlockFocus()

        source.size = NSSize(width: 200, height: 100)

        let croppedData = cropAndScaleNSImage(
            image: source,
            offsetX: 0,
            offsetY: 0,
            scale: 1,
            viewportSize: CGSize(width: 100, height: 100),
            targetSize: CGSize(width: 64, height: 64)
        )

        XCTAssertNotNil(croppedData)
        XCTAssertNotNil(croppedData.flatMap(NSImage.init(data:)))
    }

    /// 测试冻结 (setFrozen) 与解冻时状态机流转及清理
    func testManagedUserSetFrozenStateTransitions() {
        let user = ManagedUser(username: "charlie", fullName: "Charlie")
        user.isRunning = true
        user.pid = 999
        user.startedAt = Date()
        user.freezeWarning = "警告"

        // 1. 冻结时，相关运行时状态清空
        user.setFrozen(true, mode: .pause, pausedPIDs: [999, 1000], previousAutostartEnabled: true)
        XCTAssertTrue(user.isFrozen)
        XCTAssertEqual(user.freezeMode, .pause)
        XCTAssertEqual(user.pausedProcessPIDs, [999, 1000])
        XCTAssertTrue(user.freezePreviousAutostartEnabled == true)
        XCTAssertFalse(user.isRunning)
        XCTAssertNil(user.pid)
        XCTAssertNil(user.startedAt)
        XCTAssertNil(user.freezeWarning) // 冻结状态下清除旧的警告

        // 2. 解冻时，恢复正常，但并不自动开始运行
        user.freezeWarning = "解冻前警告"
        user.setFrozen(false)
        XCTAssertFalse(user.isFrozen)
        XCTAssertNil(user.freezeMode)
        XCTAssertEqual(user.pausedProcessPIDs, [])
        XCTAssertNil(user.freezePreviousAutostartEnabled)
        XCTAssertNil(user.freezeWarning)
        XCTAssertFalse(user.isRunning) // 不自动启动
    }

    /// 测试显示状态 statusLabel 的多级优先级
    func testManagedUserStatusLabelPriority() {
        let user = ManagedUser(username: "david", fullName: "David")

        // 正常空状态
        XCTAssertEqual(user.statusLabel, L10n.k("models.managed_user.not_running", fallback: "未运行"))

        // 1. 运行中
        user.isRunning = true
        XCTAssertEqual(user.statusLabel, L10n.k("models.managed_user.running", fallback: "运行中"))

        // 2. 冻结（优先级高于运行中）
        user.setFrozen(true, mode: .normal)
        XCTAssertEqual(user.statusLabel, FreezeMode.normal.statusLabel)

        user.setFrozen(true, mode: .pause)
        XCTAssertEqual(user.statusLabel, FreezeMode.pause.statusLabel)

        // 3. 错误异常（优先级最高）
        user.errorMessage = "端口冲突"
        XCTAssertEqual(user.statusLabel, "\(L10n.k("models.managed_user.error_prefix", fallback: "异常:")) 端口冲突")
    }

    /// 测试运行时名称 runtimeDisplayName 根据版本信息选择（Hermes 优先）
    func testManagedUserRuntimeDisplayName() {
        let user = ManagedUser(username: "eve", fullName: "Eve")

        XCTAssertEqual(user.runtimeDisplayName, "—")
        XCTAssertNil(user.runtimeVersionLabel)

        // 仅装有 OpenClaw
        user.openclawVersion = "2026.2.15"
        XCTAssertEqual(user.runtimeDisplayName, "OpenClaw")
        XCTAssertEqual(user.runtimeVersionLabel, "v2026.2.15")
        XCTAssertFalse(user.prefersHermesRuntime)

        // 同时也装有 Hermes（Hermes 优先）
        user.hermesVersion = "1.0.2"
        XCTAssertEqual(user.runtimeDisplayName, "Hermes")
        XCTAssertEqual(user.runtimeVersionLabel, "v1.0.2")
        XCTAssertTrue(user.prefersHermesRuntime)
    }

    /// 测试 ClawDescriptionStore 备注存储的存取、去空格与清空逻辑
    func testClawDescriptionStore() {
        let suiteName = "ManagedUserStateTests.ClawDescriptionStore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("无法创建沙盒 UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ClawDescriptionStore(defaults: defaults)

        // 默认空
        XCTAssertEqual(store.description(for: "user1"), "")

        // 正常保存与去空格
        store.setDescription("   这是我的测试节点   \n", for: "user1")
        XCTAssertEqual(store.description(for: "user1"), "这是我的测试节点")

        // 清空（写入空白字符）
        store.setDescription("   ", for: "user1")
        XCTAssertEqual(store.description(for: "user1"), "")
    }

    /// 测试 ClawFreezeStateStore 的序列化保存与清空逻辑
    func testClawFreezeStateStore() {
        let suiteName = "ManagedUserStateTests.ClawFreezeStateStore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("无法创建沙盒 UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ClawFreezeStateStore(defaults: defaults)

        // 默认无记录
        XCTAssertNil(store.frozenState(for: "user2"))

        // 保存一条记录
        let now = Date().timeIntervalSince1970
        let record = ClawFreezeStateRecord(mode: .pause, pausedPIDs: [123, 456], updatedAt: now, previousAutostartEnabled: true)
        store.setFrozenState(record, for: "user2")

        // 读取并验证
        if let saved = store.frozenState(for: "user2") {
            XCTAssertEqual(saved.mode, .pause)
            XCTAssertEqual(saved.pausedPIDs, [123, 456])
            XCTAssertEqual(saved.updatedAt, now)
            XCTAssertEqual(saved.previousAutostartEnabled, true)
        } else {
            XCTFail("读取冻结记录失败")
        }

        // 清空
        store.setFrozenState(nil, for: "user2")
        XCTAssertNil(store.frozenState(for: "user2"))
    }
}
