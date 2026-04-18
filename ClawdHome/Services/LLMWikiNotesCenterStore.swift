import Foundation
import Observation

struct LLMWikiSkillState {
    let skillKey: String
    let installed: Bool
    let disabled: Bool
    let source: String?
}

struct LLMWikiUserState: Identifiable {
    let audit: LLMWikiUserAudit
    let skillState: LLMWikiSkillState?

    var id: String { audit.username }
}

@MainActor
@Observable
final class LLMWikiNotesCenterStore {
    private let kbClient = KnowledgeBaseSocketClient()
    private let launchService = LLMWikiLaunchService()
    private let storeService = LLMWikiStoreService()

    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var appInstalled = false
    private(set) var appRunning = false
    private(set) var globalAudit: LLMWikiGlobalAudit?
    private(set) var socketStatus: LLMWikiSocketStatus?
    private(set) var healthStatus: LLMWikiHealthStatus?
    private(set) var storeSnapshot: LLMWikiStoreSnapshot = LLMWikiStoreSnapshot(
        path: LLMWikiPaths.appStatePath(for: NSUserName()),
        exists: false,
        lastProject: nil,
        recentProjects: [],
        llmConfig: nil,
        embeddingConfig: nil
    )
    private(set) var userStates: [LLMWikiUserState] = []

    var editableLLMConfig = LLMWikiStoredLLMConfig(
        provider: "openai",
        apiKey: "",
        model: "",
        ollamaUrl: "http://localhost:11434",
        customEndpoint: "",
        maxContextSize: 204800
    )
    var editableEmbeddingConfig = LLMWikiStoredEmbeddingConfig(
        enabled: false,
        endpoint: "",
        apiKey: "",
        model: ""
    )
    var llmConfigSource: LLMWikiLLMConfigSource = .manual
    var selectedGlobalLLMOptionID: String = ""
    var observedGlobalRevision: Int = 0

    private var helperSupportsLLMWikiOps: Bool {
        globalAudit != nil
    }

    func refresh(users: [ManagedUser], helperClient: HelperClient, gatewayHub: GatewayHub) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        appInstalled = launchService.isInstalled()
        appRunning = launchService.isRunning()
        storeSnapshot = storeService.load()

        if let llmConfig = storeSnapshot.llmConfig {
            editableLLMConfig = llmConfig
        }
        if let embeddingConfig = storeSnapshot.embeddingConfig {
            editableEmbeddingConfig = embeddingConfig
        }

        globalAudit = await helperClient.auditLlmWikiState()

        do {
            socketStatus = try await kbClient.status()
        } catch {
            socketStatus = nil
        }

        do {
            healthStatus = try await kbClient.health()
        } catch {
            healthStatus = nil
        }

        var nextUserStates: [LLMWikiUserState] = []
        for user in users.sorted(by: { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }) {
            guard let audit = await helperClient.auditLlmWikiUserState(username: user.username) else { continue }
            let skill = await resolveSkillState(username: user.username, gatewayHub: gatewayHub, fallbackInstalled: audit.workspaceSkillExists)
            nextUserStates.append(LLMWikiUserState(audit: audit, skillState: skill))
        }
        userStates = nextUserStates

        if helperClient.isConnected && globalAudit == nil {
            errorMessage = "LLM Wiki helper audit unavailable. The installed helper may be older than the app build."
        } else {
            errorMessage = nil
        }
    }

    func repairGlobal(helperClient: HelperClient, users: [ManagedUser], gatewayHub: GatewayHub) async {
        guard helperSupportsLLMWikiOps else {
            errorMessage = "The installed helper does not expose LLM Wiki repair APIs yet. Reinstall the helper from the current build first."
            return
        }
        do {
            try await helperClient.repairLlmWikiProject()
            try await helperClient.repairLlmWikiRuntimePermissions()
            statusMessage = "LLM Wiki 项目和 runtime 已修复"
            await refresh(users: users, helperClient: helperClient, gatewayHub: gatewayHub)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func repairUser(username: String, helperClient: HelperClient, users: [ManagedUser], gatewayHub: GatewayHub) async {
        guard helperSupportsLLMWikiOps else {
            errorMessage = "The installed helper does not expose LLM Wiki repair APIs yet. Reinstall the helper from the current build first."
            return
        }
        do {
            try await helperClient.setupLlmWikiNotes(username: username)
            try await helperClient.repairLlmWikiMapping(username: username)
            try await helperClient.repairBundledLlmWikiSkill(username: username)
            statusMessage = "@\(username) 的 LLM Wiki 目录和 skill 已修复"
            await refresh(users: users, helperClient: helperClient, gatewayHub: gatewayHub)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func launchOrRestart(helperClient: HelperClient, users: [ManagedUser], gatewayHub: GatewayHub) async {
        guard helperSupportsLLMWikiOps else {
            errorMessage = "The installed helper does not expose LLM Wiki repair APIs yet. Reinstall the helper from the current build first."
            return
        }
        do {
            try await helperClient.repairLlmWikiProject()
            try await helperClient.repairLlmWikiRuntimePermissions()
            try storeService.ensureProjectBinding(projectPath: LLMWikiPaths.projectRoot)
            if launchService.isRunning() {
                try await launchService.restartManaged()
                statusMessage = "LLM Wiki 已按 ClawdHome 模式重启"
            } else {
                try await launchService.launchManaged()
                statusMessage = "LLM Wiki 已按 ClawdHome 模式启动"
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refresh(users: users, helperClient: helperClient, gatewayHub: gatewayHub)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func bindProject(users: [ManagedUser], helperClient: HelperClient, gatewayHub: GatewayHub) async {
        do {
            try storeService.ensureProjectBinding(projectPath: LLMWikiPaths.projectRoot)
            statusMessage = "LLM Wiki 项目绑定已更新"
            await refresh(users: users, helperClient: helperClient, gatewayHub: gatewayHub)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applySuggestedLLMConfig(modelStore: GlobalModelStore) {
        let options = storeService.globalLLMConfigOptions(from: modelStore)
        guard let first = options.first else {
            errorMessage = "当前全局模型池里没有可直接映射到 LLM Wiki 的模型配置"
            return
        }
        llmConfigSource = .global
        selectedGlobalLLMOptionID = first.id
        editableLLMConfig = first.config
        observedGlobalRevision = modelStore.revision
        statusMessage = "已载入全局模型配置：\(first.title)"
    }

    func globalLLMConfigOptions(modelStore: GlobalModelStore) -> [LLMWikiGlobalLLMConfigOption] {
        storeService.globalLLMConfigOptions(from: modelStore)
    }

    func loadPersistedLLMConfigSelection(modelStore: GlobalModelStore) {
        if let selection = LLMWikiLLMConfigSelectionStore.shared.load() {
            llmConfigSource = selection.source
            selectedGlobalLLMOptionID = selection.optionID ?? ""
            observedGlobalRevision = selection.observedGlobalRevision
        }
        syncSelectedGlobalLLMOption(modelStore: modelStore)
        if observedGlobalRevision == 0 {
            observedGlobalRevision = modelStore.revision
        }
    }

    func persistLLMConfigSelection() {
        let optionID = llmConfigSource == .global ? selectedGlobalLLMOptionID.nilIfEmpty : nil
        LLMWikiLLMConfigSelectionStore.shared.save(
            source: llmConfigSource,
            optionID: optionID,
            observedGlobalRevision: observedGlobalRevision
        )
    }

    func syncSelectedGlobalLLMOption(modelStore: GlobalModelStore) {
        let options = storeService.globalLLMConfigOptions(from: modelStore)
        guard let first = options.first else {
            selectedGlobalLLMOptionID = ""
            return
        }
        if !options.contains(where: { $0.id == selectedGlobalLLMOptionID }) {
            selectedGlobalLLMOptionID = first.id
        }
    }

    func applySelectedGlobalLLMConfig(modelStore: GlobalModelStore, updateObservedRevision: Bool = false) {
        let options = storeService.globalLLMConfigOptions(from: modelStore)
        guard !options.isEmpty else {
            errorMessage = "当前全局模型池里没有可直接映射到 LLM Wiki 的模型配置"
            return
        }
        let selected = options.first(where: { $0.id == selectedGlobalLLMOptionID }) ?? options[0]
        llmConfigSource = .global
        selectedGlobalLLMOptionID = selected.id
        editableLLMConfig = selected.config
        if updateObservedRevision {
            observedGlobalRevision = modelStore.revision
        }
        statusMessage = "已从全局模型配置赋值：\(selected.title)"
    }

    func saveConfigs(users: [ManagedUser], helperClient: HelperClient, gatewayHub: GatewayHub, modelStore: GlobalModelStore) async {
        do {
            let normalizedLLM: LLMWikiStoredLLMConfig
            if llmConfigSource == .global {
                let options = storeService.globalLLMConfigOptions(from: modelStore)
                guard !options.isEmpty else {
                    errorMessage = "当前全局模型池里没有可直接映射到 LLM Wiki 的模型配置"
                    return
                }
                let selected = options.first(where: { $0.id == selectedGlobalLLMOptionID }) ?? options[0]
                selectedGlobalLLMOptionID = selected.id
                normalizedLLM = storeService.normalizedLLMConfig(selected.config)
                editableLLMConfig = normalizedLLM
                observedGlobalRevision = modelStore.revision
            } else {
                normalizedLLM = storeService.normalizedLLMConfig(editableLLMConfig)
            }
            try storeService.saveLLMConfig(normalizedLLM)
            editableLLMConfig = normalizedLLM
            try storeService.saveEmbeddingConfig(editableEmbeddingConfig)
            persistLLMConfigSelection()
            statusMessage = llmConfigSource == .global
                ? "LLM Wiki 已按全局模型配置写入本地 store"
                : "LLM Wiki 配置已写入本地 store"
            await refresh(users: users, helperClient: helperClient, gatewayHub: gatewayHub)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveSkillState(username: String, gatewayHub: GatewayHub, fallbackInstalled: Bool) async -> LLMWikiSkillState? {
        if gatewayHub.connectedUsernames.contains(username) {
            await gatewayHub.ensureSkillsStarted(for: username)
            let store = gatewayHub.skillsStore(for: username)
            if let skill = store.skills.first(where: { $0.name == LLMWikiPaths.skillName || $0.skillKey == LLMWikiPaths.skillName }) {
                return LLMWikiSkillState(
                    skillKey: skill.skillKey,
                    installed: true,
                    disabled: skill.disabled,
                    source: skill.source
                )
            }
        }

        guard fallbackInstalled else { return nil }
        return LLMWikiSkillState(skillKey: LLMWikiPaths.skillName, installed: true, disabled: false, source: "workspace")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
