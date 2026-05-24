// tests/ClawdHomeAppXCTests/HermesTeamWizardTests.swift
// 核心主流程测试 — 单元测试：Hermes 团队初始化向导状态机

import XCTest
@testable import ClawdHome

final class HermesTeamWizardTests: XCTestCase {

    /// 测试 ProfileWizardProgress 辅助方法的计算逻辑
    func testProfileWizardProgressHelpers() {
        var progress = ProfileWizardProgress()

        // 默认无绑定
        XCTAssertFalse(progress.hasUnfinishedBinding)
        XCTAssertFalse(progress.hasDoneBinding)

        // 1. 添加 pending 绑定
        progress.imBindings["feishu"] = IMBindingState(status: .pending, doneAt: nil, error: nil)
        XCTAssertTrue(progress.hasUnfinishedBinding)
        XCTAssertFalse(progress.hasDoneBinding)

        // 2. 将绑定改为 done
        progress.imBindings["feishu"] = IMBindingState(status: .done, doneAt: "2026-05-24T23:00:00Z", error: nil)
        XCTAssertFalse(progress.hasUnfinishedBinding)
        XCTAssertTrue(progress.hasDoneBinding)

        // 3. 存在 failed 绑定 (需要续作)
        progress.imBindings["wecom"] = IMBindingState(status: .failed, doneAt: nil, error: "Token Expired")
        XCTAssertTrue(progress.hasUnfinishedBinding)
        XCTAssertTrue(progress.hasDoneBinding) // 依然存在 feishu 这个已 done 的

        // 4. 忽略 deferred 和 skipped (不视为 unfinished 未完成)
        var progress2 = ProfileWizardProgress()
        progress2.imBindings["slack"] = IMBindingState(status: .deferred, doneAt: nil, error: nil)
        progress2.imBindings["discord"] = IMBindingState(status: .skipped, doneAt: nil, error: nil)
        XCTAssertFalse(progress2.hasUnfinishedBinding)
        XCTAssertFalse(progress2.hasDoneBinding)
    }

    /// 测试 TeamMember.isFullyReady 组合条件的有效性
    func testTeamMemberIsFullyReady() {
        var progress = ProfileWizardProgress()
        progress.profileCreated = true
        progress.modelConfigured = true
        progress.doctorPassed = true
        progress.gatewayStarted = true

        var member = TeamMember(id: "alice", displayName: "Alice", emoji: "🤖", progress: progress)
        XCTAssertTrue(member.isFullyReady)

        // 1. 任意一步没完成，都不算 Ready
        member.progress.gatewayStarted = false
        XCTAssertFalse(member.isFullyReady)

        // 2. 有未完成绑定不算 Ready
        member.progress.gatewayStarted = true
        member.progress.imBindings["telegram"] = IMBindingState(status: .pending, doneAt: nil, error: nil)
        XCTAssertFalse(member.isFullyReady)
    }

    /// 测试 SharedModelConfig 的验证与 Payload JSON 转换
    func testSharedModelConfig() {
        var config = SharedModelConfig()

        // 1. 验证 isValid
        XCTAssertFalse(config.isValid)
        config.provider = "gemini"
        config.modelDefault = "gemini-1.5-pro"
        XCTAssertTrue(config.isValid)

        // 2. 验证建议的环境变量 Key 名
        XCTAssertEqual(config.suggestedSecretKeyName(for: "anthropic"), "ANTHROPIC_API_KEY")
        XCTAssertEqual(config.suggestedSecretKeyName(for: "gemini"), "GOOGLE_API_KEY")
        XCTAssertEqual(config.suggestedSecretKeyName(for: "deepseek"), "DEEPSEEK_API_KEY")
        XCTAssertEqual(config.suggestedSecretKeyName(for: "openai"), "OPENAI_API_KEY")
        XCTAssertEqual(config.suggestedSecretKeyName(for: "unknown"), "OPENAI_API_KEY")

        // 3. 验证 makePayloadJSON 输出
        config.primarySecretKeyName = "GOOGLE_API_KEY"
        config.primarySecretValue = "sk-gemini-test"
        config.modelBaseURL = "https://custom.gemini.api"
        config.modelAPIMode = "chat"

        guard let jsonStr = config.makePayloadJSON(),
              let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("makePayloadJSON 输出非合法 JSON")
            return
        }

        XCTAssertEqual(dict["provider"] as? String, "gemini")
        XCTAssertEqual(dict["modelDefault"] as? String, "gemini-1.5-pro")
        XCTAssertEqual(dict["modelBaseURL"] as? String, "https://custom.gemini.api")
        XCTAssertEqual(dict["modelAPIMode"] as? String, "chat")

        guard let env = dict["env"] as? [String: String] else {
            XCTFail("env 字典构造失败")
            return
        }
        XCTAssertEqual(env["GOOGLE_API_KEY"], "sk-gemini-test")
    }

    /// 测试 applyResumePriority 决定的续作步骤及优先级（核心状态机）
    @MainActor
    func testApplyResumePriorityLevels() {
        let wizard = HermesTeamWizardState(username: "jerry")

        // 初始状态：空成员，直接去 install (scanResume 会根据 hermesInstalled 拦，此处直接调用 applyResumePriority 测试状态分流)
        wizard.members = []
        wizard.applyResumePriority()
        XCTAssertEqual(wizard.currentStep, .summary) // 空成员直接落入 summary 最终步骤

        // 初始化两个成员，此时全未做，由于 modelConfigured=false，应当匹配 优先级3 -> .llm
        var member1 = TeamMember(id: "main", displayName: "Default Agent", emoji: "🎭", progress: ProfileWizardProgress())
        var member2 = TeamMember(id: "alice", displayName: "Alice", emoji: "🤖", progress: ProfileWizardProgress())

        wizard.members = [member1, member2]
        wizard.applyResumePriority()
        XCTAssertEqual(wizard.currentStep, .llm)

        // 1. 设置模型已配置，此时匹配 优先级6（gatewayStarted 没通） -> .gateway
        wizard.members[0].progress.modelConfigured = true
        wizard.members[1].progress.modelConfigured = true
        wizard.applyResumePriority()
        XCTAssertEqual(wizard.currentStep, .gateway)

        // 2. 如果存在 member 含有 unfinished binding -> 优先级 4 -> .imBinding，定位到对应成员 idx
        // 设置 member2 (alice) 的 feishu 绑定状态为 pending
        wizard.members[1].progress.imBindings["feishu"] = IMBindingState(status: .pending, doneAt: nil, error: nil)
        wizard.applyResumePriority()
        XCTAssertEqual(wizard.currentStep, .imBinding)
        XCTAssertEqual(wizard.currentMemberIndex, 1)

        // 3. 将其改为 done，但 doctor 未过 -> 优先级 5 -> 仍留在 .imBinding
        wizard.members[1].progress.imBindings["feishu"] = IMBindingState(status: .done, doneAt: "2026", error: nil)
        wizard.members[1].progress.doctorPassed = false
        wizard.applyResumePriority()
        XCTAssertEqual(wizard.currentStep, .imBinding)
        XCTAssertEqual(wizard.currentMemberIndex, 1)

        // 4. 将成员 2 的 doctor 标记通过，匹配 优先级 6 -> .gateway
        wizard.members[1].progress.doctorPassed = true
        wizard.applyResumePriority()
        XCTAssertEqual(wizard.currentStep, .gateway)

        // 5. 将两名成员的 gateway 启动，应全部通过，进入总结 -> .summary
        wizard.members[0].progress.profileCreated = true
        wizard.members[0].progress.modelConfigured = true
        wizard.members[0].progress.doctorPassed = true
        wizard.members[0].progress.gatewayStarted = true

        wizard.members[1].progress.profileCreated = true
        wizard.members[1].progress.modelConfigured = true
        wizard.members[1].progress.doctorPassed = true
        wizard.members[1].progress.gatewayStarted = true

        wizard.applyResumePriority()
        XCTAssertEqual(wizard.currentStep, .summary)
    }

    /// 测试 state helper 方法及防越界处理
    @MainActor
    func testWizardStateHelpers() {
        let wizard = HermesTeamWizardState(username: "jerry")
        wizard.members = [
            TeamMember(id: "main", displayName: "Default", emoji: "🎭", progress: ProfileWizardProgress())
        ]

        // 正常获取
        wizard.currentMemberIndex = 0
        XCTAssertEqual(wizard.currentMember?.id, "main")

        // 越界保护
        wizard.currentMemberIndex = 5
        XCTAssertNil(wizard.currentMember)

        // 进度更新 helper
        wizard.updateProgress(for: "main") { progress in
            progress.profileCreated = true
        }
        XCTAssertTrue(wizard.members[0].progress.profileCreated)

        // 更新不存在的 ID，不崩溃
        wizard.updateProgress(for: "non-existent") { progress in
            progress.profileCreated = true
        }
    }
}
