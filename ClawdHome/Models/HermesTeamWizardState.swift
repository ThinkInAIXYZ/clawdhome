// ClawdHome/Models/HermesTeamWizardState.swift
// T4.1：Hermes 团队初始化向导状态机（@Observable ViewModel）
//
// 续作不变量（按优先级）：
//  1. hermesInstalled == false → step = .install
//  2. members 为空 → step = .members
//  3. 任意 member modelConfigured == false → step = .llm
//  4. 任意 member 任意 platform binding 状态 ∈ {pending, failed} → step = .imBinding
//  5. 任意 member doctorPassed == false 且至少一个 binding done → step = .imBinding（4d 验收子步）
//  6. 任意 member gatewayStarted == false → step = .gateway
//  全部 done → step = .summary
//
// 注：deferred / skipped 不算未完成，pending / failed 需续作

import Foundation
import Observation

// MARK: - 步骤枚举

enum HermesTeamWizardStep: Int, CaseIterable {
    case install    // Step 1：安装 Hermes
    case members    // Step 2：团队成员清单
    case llm        // Step 3：共享 LLM 配置
    case imBinding  // Step 4：IM 绑定 + doctor 验收
    case gateway    // Step 5：gateway 注册启动
    case summary    // Step 6：完成总览

    var title: String {
        switch self {
        case .install:   return "安装 Hermes"
        case .members:   return "团队成员"
        case .llm:       return "LLM 配置"
        case .imBinding: return "IM 绑定"
        case .gateway:   return "启动 Gateway"
        case .summary:   return "完成总览"
        }
    }
}

// MARK: - IM 绑定状态

enum BindingStatus: String, Codable {
    case pending
    case done
    case failed
    case skipped
    case deferred
}

// MARK: - 进度位图（对应 §4.2 schema）

struct IMBindingState: Codable {
    var status: BindingStatus
    var doneAt: String?   // ISO8601
    var error: String?
}

struct ProfileWizardProgress: Codable {
    var profileCreated: Bool = false
    var modelConfigured: Bool = false
    var imBindings: [String: IMBindingState] = [:]   // platform key -> state
    var doctorPassed: Bool = false
    var gatewayInstalled: Bool = false
    var gatewayStarted: Bool = false

    /// 是否有任意平台需要续作（pending / failed，不含 deferred / skipped）
    var hasUnfinishedBinding: Bool {
        imBindings.values.contains { $0.status == .pending || $0.status == .failed }
    }

    /// 是否有至少一个平台已完成
    var hasDoneBinding: Bool {
        imBindings.values.contains { $0.status == .done }
    }

    /// doctor 被跳过（位图中写入 "skipped" 字符串作为特殊标记）
    var doctorSkipped: Bool {
        // doctorPassed 是 Bool，所以跳过语义用独立字段表达不现实。
        // 设计上 doctorPassed=true 也被视为完成；跳过时直接置 true 即可（不阻塞）。
        doctorPassed
    }
}

// MARK: - 团队成员

struct TeamMember: Identifiable {
    var id: String          // profileID，唯一；"main" 始终首位；profileCreated 之前可改，之后由 UI 层 .disabled 保护
    var displayName: String
    var emoji: String
    var progress: ProfileWizardProgress

    /// 是否完全就绪（可进入 summary）
    var isFullyReady: Bool {
        progress.profileCreated
        && progress.modelConfigured
        && !progress.hasUnfinishedBinding
        && progress.doctorPassed
        && progress.gatewayStarted
    }
}

// MARK: - 共享 LLM 配置

struct SharedModelConfig {
    var provider: String = "openai"
    var modelDefault: String = ""
    var modelBaseURL: String = ""
    var modelAPIMode: String = ""
    var primarySecretKeyName: String = "OPENAI_API_KEY"
    var primarySecretValue: String = ""

    static let empty = SharedModelConfig()

    var isValid: Bool {
        !provider.isEmpty && !modelDefault.isEmpty
    }

    func suggestedSecretKeyName(for provider: String) -> String {
        switch provider {
        case "anthropic": return "ANTHROPIC_API_KEY"
        case "gemini":    return "GOOGLE_API_KEY"
        case "deepseek":  return "DEEPSEEK_API_KEY"
        default:          return "OPENAI_API_KEY"
        }
    }

    /// 构造 applyHermesInitConfig 的 payloadJSON
    func makePayloadJSON(extraEnv: [String: String] = [:]) -> String? {
        var env = extraEnv
        let sk = primarySecretKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sv = primarySecretValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sk.isEmpty, !sv.isEmpty {
            env[sk] = sv
        }
        var payload: [String: Any] = [
            "provider": provider.trimmingCharacters(in: .whitespacesAndNewlines),
            "modelDefault": modelDefault.trimmingCharacters(in: .whitespacesAndNewlines),
            "env": env,
        ]
        let base = modelBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty { payload["modelBaseURL"] = base }
        let mode = modelAPIMode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mode.isEmpty { payload["modelAPIMode"] = mode }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

// MARK: - 主状态机

@Observable @MainActor
final class HermesTeamWizardState {

    // MARK: 公开状态

    var username: String
    var currentStep: HermesTeamWizardStep = .install
    var members: [TeamMember] = []
    var sharedModel: SharedModelConfig = .empty
    /// Step4/5 当前处理的 profile 下标
    var currentMemberIndex: Int = 0
    var hermesInstalled: Bool = false
    var globalError: String?

    // MARK: 私有 helper

    private var helperClient: HelperClient?

    // MARK: 初始化

    init(username: String, helperClient: HelperClient? = nil) {
        self.username = username
        self.helperClient = helperClient
    }

    // MARK: - 续作扫描

    /// 开 sheet 时调用，扫描已有 profile 进度位图，定位首个未完成步
    func scanResume(helperClient: HelperClient) async {
        self.helperClient = helperClient

        // 1. 是否安装了 hermes
        let version = await helperClient.getHermesVersion(username: username)
        hermesInstalled = version != nil
        guard hermesInstalled else {
            currentStep = .install
            return
        }

        // 2. 是否有 profiles
        let fetchedProfiles: [AgentProfile]
        do {
            fetchedProfiles = try await helperClient.listHermesProfiles(username: username)
        } catch {
            fetchedProfiles = []
        }

        // 确保 main 始终存在
        var profileList = fetchedProfiles
        if !profileList.contains(where: { $0.id == "main" }) {
            profileList.insert(
                AgentProfile(id: "main", name: "默认角色", emoji: "🎭",
                             modelPrimary: nil, modelFallbacks: [], workspacePath: nil, isDefault: true),
                at: 0
            )
        } else {
            // main 移到第一位
            if let idx = profileList.firstIndex(where: { $0.id == "main" }), idx != 0 {
                let m = profileList.remove(at: idx)
                profileList.insert(m, at: 0)
            }
        }

        // 如果向导尚无成员列表，从 profiles 恢复
        if members.isEmpty {
            members = profileList.map { profile in
                TeamMember(
                    id: profile.id,
                    displayName: profile.name.isEmpty ? (profile.id == "main" ? "默认角色" : profile.id) : profile.name,
                    emoji: profile.emoji.isEmpty ? (profile.id == "main" ? "🎭" : "🤖") : profile.emoji,
                    progress: ProfileWizardProgress()
                )
            }
        }

        if members.isEmpty {
            currentStep = .members
            return
        }

        // 3. 对每个 member 拉取位图
        for i in members.indices {
            let pid = members[i].id
            let jsonStr = await helperClient.getHermesWizardState(username: username, profileID: pid)
            if let jsonStr, let progress = parseProgress(jsonStr) {
                members[i].progress = progress
            }
        }

        // 4. 按优先级决定续作步骤
        applyResumePriority()
    }

    /// 根据位图应用续作优先级（不需要 async，可在 scanResume 内和测试中复用）
    func applyResumePriority() {
        // 优先级 3：任意 member modelConfigured == false
        if members.contains(where: { !$0.progress.modelConfigured }) {
            currentStep = .llm
            return
        }

        // 优先级 4/5：任意 member 有 pending/failed binding，或 binding done 但 doctor 未过
        for (idx, member) in members.enumerated() {
            if member.progress.hasUnfinishedBinding {
                currentStep = .imBinding
                currentMemberIndex = idx
                return
            }
            if !member.progress.doctorPassed && member.progress.hasDoneBinding {
                currentStep = .imBinding
                currentMemberIndex = idx
                return
            }
        }

        // 优先级 6：任意 member gateway 未启动
        if members.contains(where: { !$0.progress.gatewayStarted }) {
            currentStep = .gateway
            return
        }

        // 全部完成
        currentStep = .summary
    }

    // MARK: - 状态持久化

    /// 把 member 的 progress 写入位图（deep-merge patch）
    func persistMember(_ member: TeamMember) async {
        guard let client = helperClient else { return }

        let progress = member.progress
        // 构造 patch JSON（对应 §4.2 steps 字段）
        var steps: [String: Any] = [
            "profileCreated": progress.profileCreated,
            "modelConfigured": progress.modelConfigured,
            "doctorPassed": progress.doctorPassed,
            "gatewayInstalled": progress.gatewayInstalled,
            "gatewayStarted": progress.gatewayStarted,
        ]
        if !progress.imBindings.isEmpty {
            var bindings: [String: [String: Any?]] = [:]
            for (key, state) in progress.imBindings {
                bindings[key] = [
                    "status": state.status.rawValue,
                    "doneAt": state.doneAt as Any?,
                    "error": state.error as Any?,
                ]
            }
            steps["imBindings"] = bindings
        }
        let patch: [String: Any] = ["steps": steps]
        guard JSONSerialization.isValidJSONObject(patch),
              let data = try? JSONSerialization.data(withJSONObject: patch),
              let patchJSON = String(data: data, encoding: .utf8) else { return }

        _ = await client.updateHermesWizardState(username: username, profileID: member.id, patchJSON: patchJSON)
    }

    // MARK: - 便利方法

    /// 在 members 数组中查找并更新 progress
    func updateProgress(for memberID: String, _ update: (inout ProfileWizardProgress) -> Void) {
        guard let idx = members.firstIndex(where: { $0.id == memberID }) else { return }
        update(&members[idx].progress)
    }

    var currentMember: TeamMember? {
        guard currentMemberIndex < members.count else { return nil }
        return members[currentMemberIndex]
    }

    // MARK: - 私有解析

    private func parseProgress(_ json: String) -> ProfileWizardProgress? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = obj["steps"] as? [String: Any] else { return nil }

        var p = ProfileWizardProgress()
        p.profileCreated   = steps["profileCreated"] as? Bool ?? false
        p.modelConfigured  = steps["modelConfigured"] as? Bool ?? false
        p.doctorPassed     = steps["doctorPassed"] as? Bool ?? false
        p.gatewayInstalled = steps["gatewayInstalled"] as? Bool ?? false
        p.gatewayStarted   = steps["gatewayStarted"] as? Bool ?? false

        if let bindingsObj = steps["imBindings"] as? [String: [String: Any]] {
            for (key, val) in bindingsObj {
                let statusRaw = val["status"] as? String ?? "pending"
                let status = BindingStatus(rawValue: statusRaw) ?? .pending
                let doneAt = val["doneAt"] as? String
                let error = val["error"] as? String
                p.imBindings[key] = IMBindingState(status: status, doneAt: doneAt, error: error)
            }
        }
        return p
    }
}
