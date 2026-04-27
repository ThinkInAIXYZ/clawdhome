// ClawdHome/Views/WizardV2/HermesTeamWizard.swift
// PR-4：Hermes 团队初始化向导（Step 1-6）
//
// 任务覆盖：T4.2 主骨架+Step1+Step6 / T4.3 Step2 / T4.4 Step3 / T4.5 Step4 / T4.6 Step5
// 扫码类（needsTerminalQR=true）在 PR-4 阶段以灰色 placeholder 卡片占位，PR-5 接入扫码终端。

import SwiftUI

// MARK: - 入口 Sheet

struct HermesTeamWizard: View {
    let username: String

    @Environment(HelperClient.self) private var helperClient
    @Environment(\.dismiss) private var dismiss

    @State private var wizardState: HermesTeamWizardState
    @State private var isScanning = true  // 初始续作扫描

    init(username: String) {
        self.username = username
        _wizardState = State(initialValue: HermesTeamWizardState(username: username))
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            Divider()
            Group {
                if isScanning {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("正在读取初始化进度…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    stepContent
                }
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 720, minHeight: 540)
        .task {
            await wizardState.scanResume(helperClient: helperClient)
            isScanning = false
        }
    }

    // MARK: - 步骤指示器

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(Array(HermesTeamWizardStep.allCases.enumerated()), id: \.offset) { idx, step in
                let isCurrent = step == wizardState.currentStep
                let isDone = step.rawValue < wizardState.currentStep.rawValue

                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(isDone ? Color.accentColor : (isCurrent ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.08)))
                            .frame(width: 22, height: 22)
                        if isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(idx + 1)")
                                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                        }
                    }
                    Text(step.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)

                if idx < HermesTeamWizardStep.allCases.count - 1 {
                    Rectangle()
                        .fill(isDone ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 步骤内容路由

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch wizardState.currentStep {
                case .install:
                    Step1InstallView(wizardState: wizardState)
                case .members:
                    Step2MembersView(wizardState: wizardState)
                case .llm:
                    Step3LLMView(wizardState: wizardState)
                case .imBinding:
                    Step4IMBindingView(wizardState: wizardState)
                case .gateway:
                    Step5GatewayView(wizardState: wizardState)
                case .summary:
                    Step6SummaryView(wizardState: wizardState, onDismiss: { dismiss() })
                }
            }
            .padding(24)
        }
    }

    // MARK: - 底部按钮栏

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if wizardState.currentStep != .install && wizardState.currentStep != .summary {
                Button("上一步") {
                    goBack()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }

            if wizardState.currentStep == .imBinding {
                Button("跳过此 profile") {
                    skipCurrentIMProfile()
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.orange)
            }

            Spacer()

            if wizardState.currentStep != .summary {
                Button(wizardState.currentStep == .gateway ? "完成配置" : "下一步") {
                    goNext()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - 导航逻辑

    private func goBack() {
        let steps = HermesTeamWizardStep.allCases
        guard let idx = steps.firstIndex(of: wizardState.currentStep), idx > 0 else { return }
        wizardState.currentStep = steps[idx - 1]
        // 若退回到 imBinding，重置 memberIndex 到第一个未完成的成员
        if wizardState.currentStep == .imBinding {
            wizardState.currentMemberIndex = 0
        }
    }

    private func goNext() {
        let steps = HermesTeamWizardStep.allCases
        guard let idx = steps.firstIndex(of: wizardState.currentStep),
              idx + 1 < steps.count else { return }
        wizardState.currentStep = steps[idx + 1]
    }

    /// 跳过当前 profile 的所有未完成 IM 绑定（设为 skipped）并前进
    private func skipCurrentIMProfile() {
        guard let member = wizardState.currentMember else { return }
        wizardState.updateProgress(for: member.id) { p in
            // 把所有 pending/failed 的绑定标记为 skipped
            for key in p.imBindings.keys where p.imBindings[key]?.status == .pending || p.imBindings[key]?.status == .failed {
                p.imBindings[key]?.status = .skipped
            }
            // doctor 也标为通过（跳过语义）
            if !p.doctorPassed { p.doctorPassed = true }
        }
        Task {
            if let m = wizardState.members.first(where: { $0.id == member.id }) {
                await wizardState.persistMember(m)
            }
        }
        // 移动到下一个 member 或进入 gateway 步骤
        let nextIdx = wizardState.currentMemberIndex + 1
        if nextIdx < wizardState.members.count {
            wizardState.currentMemberIndex = nextIdx
        } else {
            wizardState.currentStep = .gateway
        }
    }
}

// MARK: - Step 1：安装 Hermes

private struct Step1InstallView: View {
    @Bindable var wizardState: HermesTeamWizardState
    @Environment(HelperClient.self) private var helperClient

    @State private var isInstalling = false
    @State private var installError: String?
    @State private var version: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("安装 Hermes Agent", icon: "arrow.down.circle")

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: wizardState.hermesInstalled ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(wizardState.hermesInstalled ? .green : .secondary)
                        if let v = version ?? (wizardState.hermesInstalled ? "已安装" : nil) {
                            Text("Hermes v\(v)")
                        } else {
                            Text("Hermes 未安装")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if let err = installError {
                        G1ErrorView(
                            error: err,
                            retryLabel: "重试",
                            skipLabel: "取消向导",
                            editLabel: "查看日志（TODO）",
                            onRetry: { Task { await performInstall() } },
                            onSkip: { /* 取消由外部 dismiss 处理 */ },
                            onEdit: { /* TODO：PR-5 接入日志查看器 */ }
                        )
                    }

                    if !wizardState.hermesInstalled {
                        Text("Hermes Agent 是一个自进化 AI 代理框架，支持 20+ 消息平台，需要 Python 3.11+。")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack {
                            Spacer()
                            Button {
                                Task { await performInstall() }
                            } label: {
                                if isInstalling {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("安装中…")
                                    }
                                } else {
                                    Label("安装 Hermes Agent", systemImage: "arrow.down.circle")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isInstalling)
                        }
                    } else {
                        Label("已安装，正在进入下一步…", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                }
                .padding(4)
            } label: {
                Text("Hermes 状态")
                    .font(.subheadline.weight(.medium))
            }
        }
        .task {
            await checkVersion()
        }
        .onChange(of: wizardState.hermesInstalled) { _, installed in
            if installed {
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    wizardState.currentStep = .members
                }
            }
        }
    }

    private func checkVersion() async {
        version = await helperClient.getHermesVersion(username: wizardState.username)
        wizardState.hermesInstalled = version != nil
    }

    private func performInstall() async {
        isInstalling = true
        installError = nil
        do {
            try await helperClient.installHermes(username: wizardState.username)
            version = await helperClient.getHermesVersion(username: wizardState.username)
            wizardState.hermesInstalled = true
        } catch {
            installError = error.localizedDescription
        }
        isInstalling = false
    }
}

// MARK: - Step 2：团队成员清单

private struct Step2MembersView: View {
    @Bindable var wizardState: HermesTeamWizardState
    @Environment(HelperClient.self) private var helperClient

    @State private var pendingError: String?
    @State private var isCreating = false
    @State private var createErrorMemberID: String?
    @State private var createError: String?

    // 校验正则
    private let profileIDRegex = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,63}$")

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("团队成员清单", icon: "person.2")

            Text("为每个 Hermes Agent 设置唯一 ID、显示名和 Emoji。main（默认角色）始终保留。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                // 表头
                HStack(spacing: 10) {
                    Text("Emoji").font(.caption).foregroundStyle(.secondary).frame(width: 56)
                    Text("显示名").font(.caption).foregroundStyle(.secondary).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                    Text("Profile ID").font(.caption).foregroundStyle(.secondary).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                    Text("").frame(width: 24)
                }
                .padding(.horizontal, 4)

                ForEach($wizardState.members) { $member in
                    memberRow(member: $member)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            if let err = createError {
                G1ErrorView(
                    error: err,
                    retryLabel: "重试",
                    skipLabel: "删除该成员",
                    editLabel: "编辑",
                    onRetry: {
                        Task { await createPendingProfiles() }
                    },
                    onSkip: {
                        if let id = createErrorMemberID {
                            wizardState.members.removeAll { $0.id == id }
                        }
                        createError = nil
                        createErrorMemberID = nil
                    },
                    onEdit: { createError = nil }
                )
            }

            HStack {
                Button {
                    addMember()
                } label: {
                    Label("添加成员", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)

                Spacer()

                if isCreating {
                    ProgressView().controlSize(.small)
                    Text("正在创建 profile…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear {
            // 离开 Step2 时创建所有尚未创建的 profile
            Task { await createPendingProfiles() }
        }
    }

    @ViewBuilder
    private func memberRow(member: Binding<TeamMember>) -> some View {
        let m = member.wrappedValue
        let isMain = m.id == "main"
        let idValid = isMain || isValidProfileID(m.id)

        HStack(spacing: 10) {
            // Emoji
            TextField("🤖", text: member.emoji)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .disabled(isMain)

            // 显示名
            TextField("显示名", text: member.displayName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: .infinity)
                .disabled(isMain)

            // Profile ID
            VStack(alignment: .leading, spacing: 2) {
                TextField("profile-id", text: isMain ? .constant("main") : member.id)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: .infinity)
                    .disabled(isMain || m.progress.profileCreated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(!isMain && !idValid ? Color.red.opacity(0.7) : Color.clear, lineWidth: 1.5)
                    )
                if !isMain && !idValid && !m.id.isEmpty {
                    Text("ID 格式不合法（小写字母/数字，2-64位）")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                if !isMain && isValidProfileID(m.id) && isDuplicateID(m.id, excluding: m.id) {
                    Text("ID 已存在")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            // 删除按钮
            if !isMain {
                Button {
                    wizardState.members.removeAll { $0.id == m.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .frame(width: 24)
            } else {
                Spacer().frame(width: 24)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isMain ? Color.accentColor.opacity(0.05) : Color.clear)
        )
    }

    private func addMember() {
        // 生成一个唯一临时 ID（用时间戳，用户可修改）
        let baseID = "agent\(wizardState.members.count)"
        let finalID = uniqueID(base: baseID)
        wizardState.members.append(
            TeamMember(
                id: finalID,
                displayName: "",
                emoji: "🤖",
                progress: ProfileWizardProgress()
            )
        )
    }

    private func isValidProfileID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        if id == "main" { return true }
        let range = NSRange(id.startIndex..., in: id)
        return profileIDRegex.firstMatch(in: id, range: range) != nil
    }

    private func isDuplicateID(_ id: String, excluding: String) -> Bool {
        wizardState.members.filter { $0.id != excluding }.map(\.id).contains(id)
    }

    private func uniqueID(base: String) -> String {
        let existing = Set(wizardState.members.map(\.id))
        if !existing.contains(base) { return base }
        var i = 2
        while i < 1000 {
            let candidate = "\(base)\(i)"
            if !existing.contains(candidate) { return candidate }
            i += 1
        }
        return "\(base)_\(Int(Date().timeIntervalSince1970))"
    }

    private func createPendingProfiles() async {
        isCreating = true
        createError = nil
        createErrorMemberID = nil

        for member in wizardState.members where !member.progress.profileCreated {
            guard isValidProfileID(member.id), !member.id.isEmpty else { continue }
            let profile = AgentProfile(
                id: member.id,
                name: member.displayName.isEmpty ? member.id : member.displayName,
                emoji: member.emoji.isEmpty ? "🤖" : member.emoji,
                modelPrimary: nil,
                modelFallbacks: [],
                workspacePath: nil,
                isDefault: member.id == "main"
            )
            do {
                try await helperClient.createHermesProfile(username: wizardState.username, config: profile)
                wizardState.updateProgress(for: member.id) { p in p.profileCreated = true }
                if let m = wizardState.members.first(where: { $0.id == member.id }) {
                    await wizardState.persistMember(m)
                }
            } catch {
                createError = "创建 profile '\(member.id)' 失败：\(error.localizedDescription)"
                createErrorMemberID = member.id
                break
            }
        }
        isCreating = false
    }
}

// MARK: - Step 3：共享 LLM 配置

private struct Step3LLMView: View {
    @Bindable var wizardState: HermesTeamWizardState
    @Environment(HelperClient.self) private var helperClient

    @State private var isApplying = false
    @State private var applyError: String?
    @State private var applyFailedMemberID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("共享 LLM 配置", icon: "cpu")

            Text("以下配置将写入所有团队成员的 config.yaml 与 .env。")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    // Provider + Model 行
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Provider").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $wizardState.sharedModel.provider) {
                                Text("openai").tag("openai")
                                Text("anthropic").tag("anthropic")
                                Text("gemini").tag("gemini")
                                Text("deepseek").tag("deepseek")
                                Text("custom").tag("custom")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .onChange(of: wizardState.sharedModel.provider) { _, p in
                                wizardState.sharedModel.primarySecretKeyName =
                                    wizardState.sharedModel.suggestedSecretKeyName(for: p)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Model").font(.caption).foregroundStyle(.secondary)
                            TextField("gpt-4.1-mini", text: $wizardState.sharedModel.modelDefault)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("API Mode").font(.caption).foregroundStyle(.secondary)
                            TextField("responses / chat", text: $wizardState.sharedModel.modelAPIMode)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base URL（可选）").font(.caption).foregroundStyle(.secondary)
                        TextField("https://api.openai.com/v1", text: $wizardState.sharedModel.modelBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("主密钥变量名").font(.caption).foregroundStyle(.secondary)
                            TextField("OPENAI_API_KEY", text: $wizardState.sharedModel.primarySecretKeyName)
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("密钥值").font(.caption).foregroundStyle(.secondary)
                            SecureField("sk-...", text: $wizardState.sharedModel.primarySecretValue)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    if !wizardState.sharedModel.isValid {
                        Label("Provider 与 Model 不能为空", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if wizardState.sharedModel.provider == "custom" && wizardState.sharedModel.modelBaseURL.isEmpty {
                        Label("provider=custom 时 Base URL 不能为空", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(4)
            } label: {
                Text("LLM 设置")
                    .font(.subheadline.weight(.medium))
            }

            if let err = applyError {
                G1ErrorView(
                    error: err,
                    retryLabel: "重试此 profile",
                    skipLabel: "跳过此 profile",
                    editLabel: "编辑配置",
                    onRetry: { Task { await applyToAllMembers() } },
                    onSkip: {
                        if let id = applyFailedMemberID {
                            // modelConfigured=true 语义：跳过不阻塞向导
                            wizardState.updateProgress(for: id) { p in p.modelConfigured = true }
                        }
                        applyError = nil
                        applyFailedMemberID = nil
                        Task { await applyToAllMembers() }
                    },
                    onEdit: { applyError = nil }
                )
            }

            if isApplying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在写入配置…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            // 若所有成员已 modelConfigured，自动跳过
            if wizardState.members.allSatisfy({ $0.progress.modelConfigured }) {
                wizardState.currentStep = .imBinding
            }
        }
        .onDisappear {
            Task { await applyToAllMembers() }
        }
    }

    private func applyToAllMembers() async {
        guard wizardState.sharedModel.isValid else { return }
        guard let payloadJSON = wizardState.sharedModel.makePayloadJSON() else { return }
        isApplying = true
        applyError = nil

        for member in wizardState.members where !member.progress.modelConfigured {
            let (ok, err) = await helperClient.applyHermesInitConfig(
                username: wizardState.username,
                profileID: member.id,
                payloadJSON: payloadJSON
            )
            if ok {
                wizardState.updateProgress(for: member.id) { p in p.modelConfigured = true }
                if let m = wizardState.members.first(where: { $0.id == member.id }) {
                    await wizardState.persistMember(m)
                }
            } else {
                applyError = "写入 '\(member.id)' 配置失败：\(err ?? "未知错误")"
                applyFailedMemberID = member.id
                isApplying = false
                return
            }
        }
        isApplying = false
    }
}

// MARK: - Step 4：IM 绑定 + Doctor 验收

private struct Step4IMBindingView: View {
    @Bindable var wizardState: HermesTeamWizardState
    @Environment(HelperClient.self) private var helperClient

    // 当前 member 已选中的平台
    @State private var selectedPlatformKey: String? = nil
    // 表单 env 键值对（每次切换平台重置）
    @State private var formValues: [String: String] = [:]
    @State private var showOptionals = false
    @State private var isApplying = false
    @State private var applyError: String?
    @State private var isRunningDoctor = false
    @State private var doctorError: String?
    @State private var doctorResult: DoctorResult? = nil

    struct DoctorResult {
        let ok: Bool
        let platformStatuses: [String: String]   // platform -> "ready"|"missing_token"|"unknown_error"
        let raw: String
    }

    private var currentMember: TeamMember? {
        wizardState.currentMember
    }

    var body: some View {
        if let member = currentMember {
            HStack(alignment: .top, spacing: 16) {
                // 左侧：成员列表（进度概览）
                memberList

                Divider()

                // 右侧：当前成员的 IM 绑定操作区
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("IM 绑定 · \(member.emoji) \(member.displayName)", icon: "qrcode.viewfinder")

                        platformChecklist(member: member)

                        if let platform = selectedPlatform {
                            Divider()
                            platformForm(platform: platform, member: member)
                        }

                        Divider()
                        doctorSection(member: member)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 0)
        } else {
            Text("没有待处理的成员")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var memberList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("团队成员")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(Array(wizardState.members.enumerated()), id: \.offset) { idx, member in
                memberCard(member: member, isCurrent: idx == wizardState.currentMemberIndex)
                    .onTapGesture {
                        wizardState.currentMemberIndex = idx
                        resetForm()
                    }
            }
            Spacer()
        }
        .frame(width: 180)
        .padding(.vertical, 4)
    }

    private func memberCard(member: TeamMember, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(member.emoji.isEmpty ? "🤖" : member.emoji)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(member.displayName.isEmpty ? member.id : member.displayName)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                    Text("@\(member.id)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                memberStatusIcon(member: member)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isCurrent ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func memberStatusIcon(member: TeamMember) -> some View {
        if member.isFullyReady {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        } else if member.progress.hasUnfinishedBinding || !member.progress.doctorPassed {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).font(.caption)
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary).font(.caption)
        }
    }

    // 平台勾选列表
    private func platformChecklist(member: TeamMember) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("选择要绑定的 IM 平台")
                .font(.subheadline.weight(.medium))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                ForEach(HermesIMPlatformDirectory.all) { platform in
                    let binding = member.progress.imBindings[platform.key]
                    let isSelected = selectedPlatformKey == platform.key
                    let status = binding?.status

                    Button {
                        if selectedPlatformKey == platform.key {
                            selectedPlatformKey = nil
                        } else {
                            selectedPlatformKey = platform.key
                            formValues = [:]
                            showOptionals = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            statusDot(status: status)
                            Text(platform.displayName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                            if platform.needsTerminalQR {
                                Image(systemName: "qrcode")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: isSelected ? 1.5 : 1)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func statusDot(status: BindingStatus?) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 8, height: 8)
    }

    private func statusColor(_ status: BindingStatus?) -> Color {
        switch status {
        case .done:     return .green
        case .failed:   return .red
        case .skipped:  return .gray
        case .deferred: return .orange
        default:        return Color.primary.opacity(0.2)
        }
    }

    // 所选平台的表单
    @ViewBuilder
    private func platformForm(platform: HermesIMPlatformInfo, member: TeamMember) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(platform.displayName) 配置")
                .font(.subheadline.weight(.semibold))

            if platform.needsTerminalQR {
                // PR-5：真实扫码终端子视图（替换 PR-4 placeholder）
                qrBindingStep(platform: platform, member: member)
            } else {
                tokenForm(platform: platform, member: member)
            }
        }
    }

    private func qrBindingStep(platform: HermesIMPlatformInfo, member: TeamMember) -> some View {
        // PR-5：替换 PR-4 的 placeholder，嵌入真实的 HermesQRBindingStep 子视图
        VStack(alignment: .leading, spacing: 8) {
            HermesQRBindingStep(
                username: wizardState.username,
                profileID: member.id,
                platform: platform,
                onCompleted: {
                    // 扫码验收通过 → 标为 done，持久化
                    setBinding(for: member.id, platform: platform.key, status: .done)
                    selectedPlatformKey = nil
                },
                onDeferred: {
                    // 用户选择稍后完成 → 标为 deferred，持久化
                    setBinding(for: member.id, platform: platform.key, status: .deferred)
                    selectedPlatformKey = nil
                }
            )

            // 补充"跳过此平台"按钮（不同于 deferred：跳过 = 永不绑定）
            Button("跳过此平台（永不绑定）") {
                setBinding(for: member.id, platform: platform.key, status: .skipped)
                selectedPlatformKey = nil
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func tokenForm(platform: HermesIMPlatformInfo, member: TeamMember) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 必填 keys
            ForEach(platform.requiredEnvKeys, id: \.self) { key in
                envKeyField(key: key, isRequired: true)
            }

            if !platform.optionalEnvKeys.isEmpty {
                Button {
                    showOptionals.toggle()
                } label: {
                    Label(showOptionals ? "收起可选字段" : "展开可选字段", systemImage: showOptionals ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if showOptionals {
                    ForEach(platform.optionalEnvKeys, id: \.self) { key in
                        envKeyField(key: key, isRequired: false)
                    }
                }
            }

            if let err = applyError {
                G1ErrorView(
                    error: err,
                    retryLabel: "重试",
                    skipLabel: "跳过此平台",
                    editLabel: "编辑表单",
                    onRetry: { Task { await applyBinding(platform: platform, memberID: member.id) } },
                    onSkip: {
                        setBinding(for: member.id, platform: platform.key, status: .skipped)
                        applyError = nil
                    },
                    onEdit: { applyError = nil }
                )
            }

            HStack {
                Spacer()
                Button {
                    Task { await applyBinding(platform: platform, memberID: member.id) }
                } label: {
                    if isApplying {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("应用中…") }
                    } else {
                        Label("应用", systemImage: "checkmark.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplying || !requiredKeysFilled(platform: platform))
            }
        }
    }

    @ViewBuilder
    private func envKeyField(key: String, isRequired: Bool) -> some View {
        let isSecret = isSecretKey(key)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(key)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if isRequired {
                    Text("*").foregroundStyle(.red).font(.caption2)
                }
            }
            if isSecret {
                SecureField("", text: Binding(
                    get: { formValues[key] ?? "" },
                    set: { formValues[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            } else {
                TextField("", text: Binding(
                    get: { formValues[key] ?? "" },
                    set: { formValues[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func isSecretKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return lowered.contains("token") || lowered.contains("secret") || lowered.contains("password")
            || lowered.contains("key") || lowered.contains("api_key")
    }

    private func requiredKeysFilled(platform: HermesIMPlatformInfo) -> Bool {
        platform.requiredEnvKeys.allSatisfy { key in
            !(formValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // Doctor 验收区
    private func doctorSection(member: TeamMember) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Doctor 验收")
                .font(.subheadline.weight(.semibold))

            let donePlatforms = member.progress.imBindings.filter { $0.value.status == .done }.keys.sorted()
            if donePlatforms.isEmpty {
                Text("绑定至少一个平台后即可执行验收。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("已绑定平台：\(donePlatforms.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let result = doctorResult {
                    doctorResultView(result: result, member: member)
                }

                if let err = doctorError {
                    G1ErrorView(
                        error: err,
                        retryLabel: "重试 Doctor",
                        skipLabel: "跳过此 profile 的验收",
                        editLabel: "回到平台表单",
                        onRetry: { Task { await runDoctor(member: member) } },
                        onSkip: {
                            wizardState.updateProgress(for: member.id) { p in p.doctorPassed = true }
                            Task {
                                if let m = wizardState.members.first(where: { $0.id == member.id }) {
                                    await wizardState.persistMember(m)
                                }
                            }
                            doctorError = nil
                            advanceToNextMember()
                        },
                        onEdit: {
                            doctorError = nil
                            doctorResult = nil
                        }
                    )
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await runDoctor(member: member) }
                    } label: {
                        if isRunningDoctor {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("验收中…") }
                        } else {
                            Label("执行 Doctor 验收", systemImage: "stethoscope")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunningDoctor || donePlatforms.isEmpty)

                    if member.progress.doctorPassed {
                        Label("验收已通过", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func doctorResultView(result: DoctorResult, member: TeamMember) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(result.ok ? "全部平台就绪" : "部分平台未就绪", systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(result.ok ? .green : .orange)

                ForEach(result.platformStatuses.sorted(by: { $0.key < $1.key }), id: \.key) { key, status in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status == "ready" ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                        Text(key)
                            .font(.caption.bold())
                        Text("→ \(status)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - 辅助

    private var selectedPlatform: HermesIMPlatformInfo? {
        guard let key = selectedPlatformKey else { return nil }
        return HermesIMPlatformDirectory.find(key: key)
    }

    private func setBinding(for memberID: String, platform: String, status: BindingStatus) {
        let doneAt = status == .done ? ISO8601DateFormatter().string(from: Date()) : nil
        wizardState.updateProgress(for: memberID) { p in
            p.imBindings[platform] = IMBindingState(status: status, doneAt: doneAt, error: nil)
        }
        Task {
            if let m = wizardState.members.first(where: { $0.id == memberID }) {
                await wizardState.persistMember(m)
            }
        }
    }

    private func resetForm() {
        selectedPlatformKey = nil
        formValues = [:]
        showOptionals = false
        applyError = nil
        doctorError = nil
        doctorResult = nil
    }

    private func applyBinding(platform: HermesIMPlatformInfo, memberID: String) async {
        isApplying = true
        applyError = nil

        var env: [String: String] = [:]
        for key in platform.requiredEnvKeys + platform.optionalEnvKeys {
            if let val = formValues[key], !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                env[key] = val
            }
        }

        let bindingPayload: [String: Any] = [
            "platform": platform.key,
            "env": env
        ]
        guard JSONSerialization.isValidJSONObject(bindingPayload),
              let data = try? JSONSerialization.data(withJSONObject: bindingPayload),
              let payloadJSON = String(data: data, encoding: .utf8) else {
            applyError = "序列化 IM 绑定 payload 失败"
            isApplying = false
            return
        }

        let (ok, err) = await helperClient.applyHermesIMBinding(
            username: wizardState.username,
            profileID: memberID,
            payloadJSON: payloadJSON
        )

        if ok {
            let doneAt = ISO8601DateFormatter().string(from: Date())
            wizardState.updateProgress(for: memberID) { p in
                p.imBindings[platform.key] = IMBindingState(status: .done, doneAt: doneAt, error: nil)
            }
            if let m = wizardState.members.first(where: { $0.id == memberID }) {
                await wizardState.persistMember(m)
            }
        } else {
            applyError = err ?? "绑定失败"
            wizardState.updateProgress(for: memberID) { p in
                p.imBindings[platform.key] = IMBindingState(status: .failed, doneAt: nil, error: err)
            }
            if let m = wizardState.members.first(where: { $0.id == memberID }) {
                await wizardState.persistMember(m)
            }
        }
        isApplying = false
    }

    private func runDoctor(member: TeamMember) async {
        isRunningDoctor = true
        doctorError = nil
        doctorResult = nil

        let jsonStr = await helperClient.runHermesDoctor(username: wizardState.username, profileID: member.id)

        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            doctorError = "Doctor 返回结果解析失败：\(jsonStr)"
            isRunningDoctor = false
            return
        }

        let ok = obj["ok"] as? Bool ?? false
        let platforms = obj["platforms"] as? [String: String] ?? [:]
        let raw = obj["raw"] as? String ?? ""

        doctorResult = DoctorResult(ok: ok, platformStatuses: platforms, raw: raw)

        // 判断是否所有已绑平台都 ready
        let failedPlatforms = platforms.filter { $0.value != "ready" }
        if failedPlatforms.isEmpty || ok {
            // 验收通过
            wizardState.updateProgress(for: member.id) { p in p.doctorPassed = true }
            if let m = wizardState.members.first(where: { $0.id == member.id }) {
                await wizardState.persistMember(m)
            }
            // 延迟 0.5s 再前进，让用户看到结果
            try? await Task.sleep(for: .milliseconds(600))
            advanceToNextMember()
        } else {
            let failList = failedPlatforms.map { "\($0.key): \($0.value)" }.joined(separator: "；")
            doctorError = "以下平台未就绪：\(failList)"
        }
        isRunningDoctor = false
    }

    private func advanceToNextMember() {
        let nextIdx = wizardState.currentMemberIndex + 1
        if nextIdx < wizardState.members.count {
            wizardState.currentMemberIndex = nextIdx
            resetForm()
        } else {
            wizardState.currentStep = .gateway
        }
    }
}

// MARK: - Step 5：Gateway 注册启动

private struct Step5GatewayView: View {
    @Bindable var wizardState: HermesTeamWizardState
    @Environment(HelperClient.self) private var helperClient

    @State private var isProcessing = false
    @State private var currentProcessingID: String?
    @State private var gatewayError: String?
    @State private var gatewayFailedMemberID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Gateway 启动", icon: "play.circle")

            Text("为每个成员注册并启动 Hermes Gateway，默认加入开机自启白名单。")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(wizardState.members) { member in
                        memberGatewayRow(member: member)
                    }
                }
                .padding(4)
            } label: {
                Text("Gateway 状态")
                    .font(.subheadline.weight(.medium))
            }

            if let err = gatewayError {
                G1ErrorView(
                    error: err,
                    retryLabel: "重试",
                    skipLabel: "跳过此 profile Gateway",
                    editLabel: "查看日志（TODO）",
                    onRetry: { Task { await startAllPendingGateways() } },
                    onSkip: {
                        if let id = gatewayFailedMemberID {
                            wizardState.updateProgress(for: id) { p in
                                p.gatewayStarted = true
                                p.gatewayInstalled = true
                            }
                        }
                        gatewayError = nil
                        gatewayFailedMemberID = nil
                        Task { await startAllPendingGateways() }
                    },
                    onEdit: { gatewayError = nil }
                )
            }

            HStack {
                Spacer()
                Button {
                    Task { await startAllPendingGateways() }
                } label: {
                    if isProcessing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("启动中…") }
                    } else if wizardState.members.allSatisfy({ $0.progress.gatewayStarted }) {
                        Label("全部已启动", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("启动所有 Gateway", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || wizardState.members.allSatisfy({ $0.progress.gatewayStarted }))
            }
        }
        .onAppear {
            // 若所有 gateway 已启动，自动跳过
            if wizardState.members.allSatisfy({ $0.progress.gatewayStarted }) {
                wizardState.currentStep = .summary
            } else {
                Task { await startAllPendingGateways() }
            }
        }
    }

    private func memberGatewayRow(member: TeamMember) -> some View {
        HStack(spacing: 10) {
            Text(member.emoji.isEmpty ? "🤖" : member.emoji)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName.isEmpty ? member.id : member.displayName)
                    .font(.callout.weight(.medium))
                Text("@\(member.id)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if member.id == currentProcessingID, isProcessing {
                ProgressView().controlSize(.small)
                Text("启动中…").font(.caption).foregroundStyle(.secondary)
            } else if member.progress.gatewayStarted {
                Label("已启动", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Label("等待", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func startAllPendingGateways() async {
        isProcessing = true
        for member in wizardState.members where !member.progress.gatewayStarted {
            currentProcessingID = member.id

            // 1. 加入自启白名单（幂等）
            try? await helperClient.setHermesAutostartProfile(
                username: wizardState.username,
                profileID: member.id,
                enabled: true
            )

            // 2. 启动 gateway
            do {
                try await helperClient.startHermesGateway(
                    username: wizardState.username,
                    profileID: member.id
                )
                // 验真：查询状态
                let status = await helperClient.getHermesGatewayStatus(
                    username: wizardState.username,
                    profileID: member.id
                )
                if status.running {
                    wizardState.updateProgress(for: member.id) { p in
                        p.gatewayStarted = true
                        p.gatewayInstalled = true
                    }
                    if let m = wizardState.members.first(where: { $0.id == member.id }) {
                        await wizardState.persistMember(m)
                    }
                } else {
                    gatewayError = "gateway '\(member.id)' 启动后未检测到运行状态"
                    gatewayFailedMemberID = member.id
                    isProcessing = false
                    currentProcessingID = nil
                    return
                }
            } catch {
                gatewayError = "启动 gateway '\(member.id)' 失败：\(error.localizedDescription)"
                gatewayFailedMemberID = member.id
                isProcessing = false
                currentProcessingID = nil
                return
            }
        }
        currentProcessingID = nil
        isProcessing = false

        // 全部完成 → 进入 summary
        if wizardState.members.allSatisfy({ $0.progress.gatewayStarted }) {
            wizardState.currentStep = .summary
        }
    }
}

// MARK: - Step 6：完成总览

private struct Step6SummaryView: View {
    let wizardState: HermesTeamWizardState
    let onDismiss: () -> Void

    @State private var copied = false

    private var readyCount: Int {
        wizardState.members.filter { $0.isFullyReady }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("团队初始化完成", icon: "checkmark.seal.fill")

            Text("恭喜！\(readyCount)/\(wizardState.members.count) 个 agent 已就绪。")
                .font(.title3.weight(.semibold))
                .foregroundStyle(readyCount == wizardState.members.count ? .green : .orange)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(wizardState.members) { member in
                        summaryRow(member: member)
                    }
                }
                .padding(4)
            } label: {
                Text("团队状态").font(.subheadline.weight(.medium))
            }

            HStack(spacing: 10) {
                Button {
                    copyStatusJSON()
                } label: {
                    Label(copied ? "已复制" : "复制状态摘要", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("完成") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func summaryRow(member: TeamMember) -> some View {
        let doneCount = member.progress.imBindings.values.filter { $0.status == .done }.count
        let deferredCount = member.progress.imBindings.values.filter { $0.status == .deferred }.count

        return HStack(spacing: 10) {
            Text(member.emoji.isEmpty ? "🤖" : member.emoji)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName.isEmpty ? member.id : member.displayName)
                    .font(.callout.weight(.semibold))
                HStack(spacing: 6) {
                    Text(member.progress.gatewayStarted ? "运行中" : "已停止")
                        .font(.caption)
                        .foregroundStyle(member.progress.gatewayStarted ? .green : .secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    Text("绑定 \(doneCount) 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if deferredCount > 0 {
                        Text("· 待补 \(deferredCount) 个")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if member.isFullyReady {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if deferredCount > 0 {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
            } else {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func copyStatusJSON() {
        var membersJSON: [[String: Any]] = []
        for member in wizardState.members {
            var bindings: [String: String] = [:]
            for (k, v) in member.progress.imBindings {
                bindings[k] = v.status.rawValue
            }
            let row: [String: Any] = [
                "id": member.id,
                "displayName": member.displayName,
                "gatewayStarted": member.progress.gatewayStarted,
                "doctorPassed": member.progress.doctorPassed,
                "imBindings": bindings,
            ]
            membersJSON.append(row)
        }
        let payload: [String: Any] = [
            "username": wizardState.username,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "members": membersJSON,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
           let text = String(data: data, encoding: .utf8) {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
    }
}

// MARK: - G1 三按钮错误组件

struct G1ErrorView: View {
    let error: String
    let retryLabel: String
    let skipLabel: String
    let editLabel: String
    let onRetry: () -> Void
    let onSkip: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error, systemImage: "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button(retryLabel, action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                Button(skipLabel, action: onSkip)
                    .buttonStyle(.bordered)
                Button(editLabel, action: onEdit)
                    .buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - 共享工具

private func sectionHeader(_ title: String, icon: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: icon)
            .font(.title3)
            .foregroundStyle(Color.accentColor)
        Text(title)
            .font(.title3.weight(.semibold))
    }
}
