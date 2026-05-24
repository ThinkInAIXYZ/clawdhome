// tests/ClawdHomeAppXCTests/ShrimpPoolLogicTests.swift
// 核心主流程测试 — 单元测试：ShrimpPool 引导状态决策与一次性状态消费

import XCTest
@testable import ClawdHome

final class ShrimpPoolLogicTests: XCTestCase {

    /// 测试 ShrimpPool.resolveWizardCompleted 静态逻辑 (向导是否已完成的判定分支)
    @MainActor
    func testResolveWizardCompletedBranches() {
        // 分支 1：无 JSON (stateJSON 为空/非法) + 有运行时安装 (hasRuntime = true) -> 认为已完成，跳过向导直接进详情
        XCTAssertTrue(ShrimpPool.resolveWizardCompleted(stateJSON: "", hasRuntime: true))

        // 分支 2：无 JSON (stateJSON 为空/非法) + 无运行时安装 (hasRuntime = false) -> 认为未完成，进入向导
        XCTAssertFalse(ShrimpPool.resolveWizardCompleted(stateJSON: "", hasRuntime: false))

        // 分支 3：有 JSON 但无法解析 -> 降级按照“无 JSON”退回逻辑测试
        XCTAssertTrue(ShrimpPool.resolveWizardCompleted(stateJSON: "invalid_json_string", hasRuntime: true))
        XCTAssertFalse(ShrimpPool.resolveWizardCompleted(stateJSON: "invalid_json_string", hasRuntime: false))

        // 分支 4：有合法 JSON，且 completedAt != nil (或者 steps["finish"] == "done") -> 无论是否有运行时，均认为已完成
        var stateCompleted = InitWizardState()
        stateCompleted.completedAt = Date()
        let completedJSON = stateCompleted.toJSON()
        XCTAssertTrue(ShrimpPool.resolveWizardCompleted(stateJSON: completedJSON, hasRuntime: true))
        XCTAssertTrue(ShrimpPool.resolveWizardCompleted(stateJSON: completedJSON, hasRuntime: false))

        // 分支 5：有合法 JSON，未完成，但有进度 (active = true 或 steps 中有非 pending) + 无运行时 -> 认为未完成 (要继续向导)
        var stateWithProgress = InitWizardState()
        stateWithProgress.active = true
        let progressJSON = stateWithProgress.toJSON()
        XCTAssertFalse(ShrimpPool.resolveWizardCompleted(stateJSON: progressJSON, hasRuntime: false))

        // 分支 6：有合法 JSON，未完成，且没有进度 (active = false 且 steps 全 pending) + 有运行时 -> 认为已完成 (避免新用户没走完向导但被后台拉起后被卡住)
        var stateNoProgress = InitWizardState()
        stateNoProgress.active = false
        stateNoProgress.steps = ["basicEnvironment": "pending", "finish": "pending"]
        let noProgressJSON = stateNoProgress.toJSON()
        XCTAssertTrue(ShrimpPool.resolveWizardCompleted(stateJSON: noProgressJSON, hasRuntime: true))
    }

    /// 测试 markNeedsOnboarding 和 consumeNeedsOnboarding 一次性消费语义与大小写不敏感设计
    @MainActor
    func testOnboardingFlagIsConsumedOnceAndCaseInsensitive() {
        let helper = HelperClient()
        let pool = ShrimpPool(helperClient: helper)

        // 默认不应需要 onboarding
        XCTAssertFalse(pool.consumeNeedsOnboarding(username: "alice"))

        // 标记 "Alice" 需要引导 (注意大小写混合)
        pool.markNeedsOnboarding(username: "Alice")

        // 第一次消费，用全小写 "alice" 应当成功匹配并返回 true
        XCTAssertTrue(pool.consumeNeedsOnboarding(username: "alice"))

        // 第二次消费，已被移除，应当返回 false
        XCTAssertFalse(pool.consumeNeedsOnboarding(username: "alice"))

        // 再次标记 "bob"，消费 "BOB" 应当成功 (大小写不敏感)
        pool.markNeedsOnboarding(username: "bob")
        XCTAssertTrue(pool.consumeNeedsOnboarding(username: "BOB"))
    }

    /// 测试 stageInitTeam 和 consumeInitTeam 一次性消费语义与大小写不敏感设计
    @MainActor
    func testInitTeamStagedAndConsumedOnceAndCaseInsensitive() {
        let helper = HelperClient()
        let pool = ShrimpPool(helperClient: helper)

        // 默认空
        XCTAssertNil(pool.consumeInitTeam(for: "charlie"))

        // 预备一个 TeamDNA
        let agent1 = AgentDNA(
            id: "dna1", name: "Agent 1", emoji: "🤖", soul: "soul-test",
            skills: [], category: "utility", version: "1.0",
            fileSoul: nil, fileIdentity: nil, fileUser: nil, suggestedAgentID: nil
        )
        let teamDNA = TeamDNA(
            id: "team1", teamName: "Test Team", teamEmoji: "👥",
            suggestedInstanceID: "team-instance-id", members: [agent1]
        )

        // 暂存 "Charlie" (大小写混合)
        pool.stageInitTeam(teamDNA, for: "Charlie")

        // 第一次消费，使用小写 "charlie"，应当返回构造的 TeamDNA，并匹配字段
        guard let consumed = pool.consumeInitTeam(for: "charlie") else {
            XCTFail("无法消费已暂存的团队 DNA")
            return
        }
        XCTAssertEqual(consumed.id, "team1")
        XCTAssertEqual(consumed.teamName, "Test Team")
        XCTAssertEqual(consumed.members.count, 1)

        // 第二次消费，已被移除，应当返回 nil
        XCTAssertNil(pool.consumeInitTeam(for: "charlie"))
    }
}
