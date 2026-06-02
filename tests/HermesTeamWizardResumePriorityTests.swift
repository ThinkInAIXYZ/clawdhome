// tests/HermesTeamWizardResumePriorityTests.swift
// 核心主流程测试 — 命令行参考测试：Hermes 团队向导恢复步优先级状态转移机制

import Foundation

// 模拟向导步骤
enum HermesTeamWizardStep: Int, CaseIterable {
    case install
    case members
    case llm
    case imBinding
    case gateway
    case summary
}

// 模拟 IM 绑定状态
enum BindingStatus: String, Codable {
    case pending
    case done
    case failed
    case skipped
    case deferred
}

struct IMBindingState {
    var status: BindingStatus
}

struct ProfileWizardProgress {
    var profileCreated: Bool = false
    var modelConfigured: Bool = false
    var imBindings: [String: IMBindingState] = [:]
    var doctorPassed: Bool = false
    var gatewayStarted: Bool = false

    var hasUnfinishedBinding: Bool {
        imBindings.values.contains { $0.status == .pending || $0.status == .failed }
    }

    var hasDoneBinding: Bool {
        imBindings.values.contains { $0.status == .done }
    }
}

struct TeamMember {
    var id: String
    var progress: ProfileWizardProgress
}

// 模拟向导状态机
struct HermesWizardStateEvaluator {
    static func resolveStep(members: [TeamMember], hermesInstalled: Bool) -> (step: HermesTeamWizardStep, memberIndex: Int) {
        // 优先级 1：未安装 Hermes
        guard hermesInstalled else {
            return (.install, 0)
        }

        // 优先级 2：团队成员列表为空
        guard !members.isEmpty else {
            return (.members, 0)
        }

        // 优先级 3：任意成员的 LLM 未配置 (modelConfigured == false)
        if members.contains(where: { !$0.progress.modelConfigured }) {
            return (.llm, 0)
        }

        // 优先级 4 & 5：处理 IM 绑定
        for (idx, member) in members.enumerated() {
            // 优先级 4：有 pending 或 failed 的绑定需要继续做
            if member.progress.hasUnfinishedBinding {
                return (.imBinding, idx)
            }
            // 优先级 5：有绑定已 done，但验收 (doctorPassed) 未通过
            if !member.progress.doctorPassed && member.progress.hasDoneBinding {
                return (.imBinding, idx)
            }
        }

        // 优先级 6：任意成员 gateway 未启动
        if members.contains(where: { !$0.progress.gatewayStarted }) {
            return (.gateway, 0)
        }

        // 全部通过，进入总结
        return (.summary, 0)
    }
}

struct HermesTeamWizardResumePriorityTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        // 1. 优先级 1：未安装
        let (step1, _) = HermesWizardStateEvaluator.resolveStep(members: [], hermesInstalled: false)
        expect(step1 == .install, "未安装 Hermes 应去往 .install")

        // 2. 优先级 2：空成员
        let (step2, _) = HermesWizardStateEvaluator.resolveStep(members: [], hermesInstalled: true)
        expect(step2 == .members, "成员为空应去往 .members")

        // 3. 优先级 3：未配置 LLM
        let m1 = TeamMember(id: "main", progress: ProfileWizardProgress(profileCreated: true, modelConfigured: false))
        let (step3, _) = HermesWizardStateEvaluator.resolveStep(members: [m1], hermesInstalled: true)
        expect(step3 == .llm, "有成员未配置模型应去往 .llm")

        // 4. 优先级 4：有未完成绑定（以 alice 为例）
        var mAliceProgress = ProfileWizardProgress(profileCreated: true, modelConfigured: true)
        mAliceProgress.imBindings["feishu"] = IMBindingState(status: .pending)
        let mAlice = TeamMember(id: "alice", progress: mAliceProgress)

        let (step4, idx4) = HermesWizardStateEvaluator.resolveStep(members: [mAlice], hermesInstalled: true)
        expect(step4 == .imBinding, "有 pending 绑定应去往 .imBinding")
        expect(idx4 == 0, "匹配索引应为 0")

        // 5. 优先级 5：绑定 done 但 doctor 验收未过
        var mBobProgress = ProfileWizardProgress(profileCreated: true, modelConfigured: true)
        mBobProgress.imBindings["feishu"] = IMBindingState(status: .done)
        mBobProgress.doctorPassed = false
        let mBob = TeamMember(id: "bob", progress: mBobProgress)

        let (step5, idx5) = HermesWizardStateEvaluator.resolveStep(members: [mBob], hermesInstalled: true)
        expect(step5 == .imBinding, "绑定 done 且 doctor 没过应去往 .imBinding")
        expect(idx5 == 0, "匹配索引应为 0")

        // 6. 优先级 6：Gateway 未启动
        var mCharlieProgress = ProfileWizardProgress(profileCreated: true, modelConfigured: true, doctorPassed: true)
        mCharlieProgress.imBindings["feishu"] = IMBindingState(status: .done)
        mCharlieProgress.gatewayStarted = false
        let mCharlie = TeamMember(id: "charlie", progress: mCharlieProgress)

        let (step6, _) = HermesWizardStateEvaluator.resolveStep(members: [mCharlie], hermesInstalled: true)
        expect(step6 == .gateway, "gateway 未启动应去往 .gateway")

        // 7. 特殊验证：skipped/deferred 不阻塞
        var mDaveProgress = ProfileWizardProgress(profileCreated: true, modelConfigured: true, doctorPassed: true)
        mDaveProgress.imBindings["wecom"] = IMBindingState(status: .skipped)
        mDaveProgress.imBindings["feishu"] = IMBindingState(status: .deferred)
        mDaveProgress.gatewayStarted = true
        let mDave = TeamMember(id: "dave", progress: mDaveProgress)

        let (step7, _) = HermesWizardStateEvaluator.resolveStep(members: [mDave], hermesInstalled: true)
        expect(step7 == .summary, "绑定被跳过或延后且 gateway 启动，应直接通过进入 .summary")

        print("Hermes team wizard resume priority reference tests passed.")
    }
}

HermesTeamWizardResumePriorityTests.main()
