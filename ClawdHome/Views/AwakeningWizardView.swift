// ClawdHome/Views/AwakeningWizardView.swift
// 角色唤醒向导：3步 Modal，原型阶段确认后只打印 log

import SwiftUI

struct AwakeningExistingUser: Equatable {
    let username: String
    let fullName: String
}

struct AwakeningWizardView: View {
    let dna: AgentDNA
    @Binding var isPresented: Bool
    let existingUsers: [AwakeningExistingUser]
    var onDismiss: (() -> Void)? = nil
    /// 正式唤醒回调 (username, fullName, description, soul, identity, userProfile)，由调用方负责创建用户并打开初始化向导
    var onAwaken: ((String, String, String, String, String, String) async throws -> Void)? = nil

    @State private var step = 1
    @State private var displayName = ""
    @State private var osUsername = ""
    @State private var osUsernameError: String? = nil
    @State private var displayNameError: String? = nil
    @State private var osUsernameConflictError: String? = nil
    @State private var submitError: String? = nil
    @State private var isSubmitting = false

    // 可编辑的文件内容（从 DNA 初始化）
    @State private var editedSoul: String = ""
    @State private var editedIdentity: String = ""
    @State private var editedUser: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 进度指示
            StepIndicator(current: step, total: 3)
                .padding(.top, 20)
                .padding(.bottom, 16)

            // 步骤内容（可滚动）
            ScrollView {
                Group {
                    switch step {
                    case 1:
                        Step1View(
                            dna: dna,
                            editedSoul: $editedSoul,
                            editedIdentity: $editedIdentity,
                            editedUser: $editedUser
                        )
                    case 2:
                        Step2View(
                            displayName: $displayName,
                            displayNameError: $displayNameError,
                            osUsername: $osUsername,
                            osUsernameError: $osUsernameError,
                            osUsernameConflictError: $osUsernameConflictError
                        )
                    case 3:
                        Step3View(dna: dna, displayName: displayName, osUsername: osUsername)
                    default:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            Divider()
                .padding(.top, 4)

            // 隐私提示横幅
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
                    .padding(.top, 1)
                Text(
                    L10n.k(
                        "views.awakening_wizard_view.privacy_banner",
                        fallback: "您正在将此数字生命基因从云端下载到您的本地设备。所有后续数据交互、知识库构建都将发生在您的物理节点内，绝对隐私，云端隔离。"
                    )
                )
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.07))

            if let submitError {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .padding(.top, 1)
                        Text(submitError)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Text(L10n.k("views.awakening_wizard_view.fix_and_retry_hint", fallback: "请点击“← 返回”修改后重试。"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(L10n.k("views.awakening_wizard_view.back_to_edit", fallback: "返回修改")) {
                            step = 2
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isSubmitting)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
                .padding(.top, 10)
            }

            // 底部按钮
            HStack(spacing: 12) {
                if step > 1 {
                    Button(L10n.k("views.awakening_wizard_view.back", fallback: "← 返回")) { step -= 1 }
                        .buttonStyle(.bordered)
                        .disabled(isSubmitting)
                } else {
                    Button(L10n.k("views.awakening_wizard_view.cancel", fallback: "取消")) {
                        isPresented = false
                        onDismiss?()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)
                }

                Button(action: handleNext) {
                    Text(
                        step == 3
                        ? (
                            isSubmitting
                            ? L10n.k("views.awakening_wizard_view.awakening", fallback: "唤醒中…")
                            : L10n.k("views.awakening_wizard_view.awaken_now", fallback: "正式唤醒 🦞")
                        )
                        : L10n.k("views.awakening_wizard_view.next", fallback: "下一步 →")
                    )
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProceed)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .onAppear {
            // 从 DNA 初始化可编辑内容
            editedSoul     = dna.fileSoul     ?? ""
            editedIdentity = dna.fileIdentity ?? ""
            editedUser     = dna.fileUser     ?? ""
            // OS 用户名预填充
            if let suggested = dna.suggestedUsername, !suggested.isEmpty {
                osUsername = suggested
            }
            // 显示名预填充为角色名
            displayName = dna.name
            validateStep2Realtime()
        }
        .onChange(of: displayName) { _, _ in
            validateStep2Realtime()
        }
        .onChange(of: osUsername) { _, _ in
            validateStep2Realtime()
        }
        .overlay {
            if isSubmitting {
                ZStack {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.large)
                        Text(L10n.k("views.awakening_wizard_view.creating_shrimp_and_starting_wizard", fallback: "正在创建虾并启动初始化向导…"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(L10n.k("views.awakening_wizard_view.usually_takes_3_8_seconds", fallback: "通常需要 3-8 秒，请稍候"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .transition(.opacity)
            }
        }
    }

    var canProceed: Bool {
        if isSubmitting { return false }
        switch step {
        case 1: return true
        case 2:
            return isValidOSUsername(osUsername)
                && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
                && conflictErrorForDisplayName(displayName) == nil
                && conflictErrorForUsername(osUsername) == nil
        case 3: return true
        default: return false
        }
    }

    func handleNext() {
        submitError = nil
        if step == 2 {
            let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDisplayName.isEmpty else {
                displayNameError = "显示名不能为空"
                return
            }
            guard isValidOSUsername(osUsername) else {
                osUsernameError = L10n.k("views.awakening_wizard_view.os_username_error", fallback: "以字母开头，只允许字母、数字、下划线")
                return
            }
            if let usernameConflict = conflictErrorForUsername(osUsername) {
                osUsernameConflictError = usernameConflict
                return
            }
            if let displayNameConflict = conflictErrorForDisplayName(displayName) {
                displayNameError = displayNameConflict
                return
            }
            displayNameError = nil
            osUsernameError = nil
            osUsernameConflictError = nil
        }
        if step < 3 {
            step += 1
        } else {
            guard !isSubmitting else { return }
            isSubmitting = true

            // 正式唤醒：触发创建用户并进入初始化向导
            let finalDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalUsername = osUsername.trimmingCharacters(in: .whitespacesAndNewlines)

            Task {
                do {
                    try await onAwaken?(finalUsername, finalDisplayName, dna.name, editedSoul, editedIdentity, editedUser)
                    await MainActor.run {
                        isSubmitting = false
                        isPresented = false
                        onDismiss?()
                    }
                } catch {
                    await MainActor.run {
                        isSubmitting = false
                        submitError = error.localizedDescription
                    }
                }
            }
        }
    }

    func isValidOSUsername(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.range(of: "^[a-zA-Z][a-zA-Z0-9_]*$", options: .regularExpression) != nil
    }

    private func validateStep2Realtime() {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDisplayName.isEmpty {
            displayNameError = nil
        } else {
            displayNameError = conflictErrorForDisplayName(displayName)
        }

        let trimmedUsername = osUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUsername.isEmpty {
            osUsernameError = nil
            osUsernameConflictError = nil
            return
        }

        if isValidOSUsername(trimmedUsername) {
            osUsernameError = nil
            osUsernameConflictError = conflictErrorForUsername(trimmedUsername)
        } else {
            osUsernameError = L10n.k("views.awakening_wizard_view.os_username_error", fallback: "以字母开头，只允许字母、数字、下划线")
            osUsernameConflictError = nil
        }
    }

    private func conflictErrorForDisplayName(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if existingUsers.contains(where: { $0.fullName.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return "显示名“\(normalized)”已被使用，请换一个名字"
        }
        return nil
    }

    private func conflictErrorForUsername(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if existingUsers.contains(where: { $0.username.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return "用户名 @\(normalized) 已存在，请换一个再试"
        }
        return nil
    }
}

// MARK: - 步骤指示器

struct StepIndicator: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: i == current ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.3), value: current)
            }
        }
    }
}

// MARK: - Step 1: 角色名片 + 可编辑文件

struct Step1View: View {
    let dna: AgentDNA
    @Binding var editedSoul: String
    @Binding var editedIdentity: String
    @Binding var editedUser: String

    var body: some View {
        VStack(spacing: 0) {
            // ── 角色名片区 ──
            VStack(spacing: 10) {
                Text(dna.emoji)
                    .font(.system(size: 52))

                Text(dna.name)
                    .font(.system(size: 20, weight: .bold))

                Text("\u{201C}\(dna.soul)\u{201D}")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .italic()
                    .lineSpacing(2)

                // 技能标签 — 横向自然流式排列
                HStack(spacing: 6) {
                    ForEach(dna.skills, id: \.self) { skill in
                        Text("#\(skill)")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 16)

            Divider()
                .padding(.bottom, 12)

            // ── 可编辑文件区 ──
            VStack(spacing: 8) {
                DNAFileEditor(
                    icon: "heart.text.square.fill",
                    iconColor: .pink,
                    title: L10n.k("views.awakening_wizard_view.soul_title", fallback: "核心价值观"),
                    subtitle: "SOUL",
                    text: $editedSoul
                )
                DNAFileEditor(
                    icon: "person.text.rectangle.fill",
                    iconColor: .purple,
                    title: L10n.k("views.awakening_wizard_view.identity_title", fallback: "身份设定"),
                    subtitle: "IDENTITY",
                    text: $editedIdentity
                )
                DNAFileEditor(
                    icon: "person.crop.circle.fill",
                    iconColor: .orange,
                    title: L10n.k("views.awakening_wizard_view.user_title", fallback: "我的画像"),
                    subtitle: "USER",
                    text: $editedUser
                )
            }
        }
    }
}

// MARK: - DNA 文件折叠编辑器

struct DNAFileEditor: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let initiallyExpanded: Bool
    @Binding var text: String

    @State private var isExpanded: Bool

    init(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        initiallyExpanded: Bool = false,
        text: Binding<String>
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.initiallyExpanded = initiallyExpanded
        _text = text
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 折叠头
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundColor(iconColor)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(subtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.28), value: isExpanded)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            // 展开区：TextEditor
            if isExpanded {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(8)
                    .scrollContentBackground(.hidden) // 隐藏系统默认背景
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Step 2: 个性化起名

struct Step2View: View {
    @Binding var displayName: String
    @Binding var displayNameError: String?
    @Binding var osUsername: String
    @Binding var osUsernameError: String?
    @Binding var osUsernameConflictError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.k("views.awakening_wizard_view.name_your_companion", fallback: "给 TA 起个名字"))
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.k("views.awakening_wizard_view.display_name", fallback: "显示名"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(L10n.k("views.awakening_wizard_view.role_display_name", fallback: "角色显示名称"), text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                if let err = displayNameError {
                    Label(err, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.k("views.awakening_wizard_view.independent_macos_username", fallback: "独立 macOS 用户名（安全隔离）"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(L10n.k("views.awakening_wizard_view.system_username", fallback: "系统用户名"), text: $osUsername)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                if let err = osUsernameError {
                    Label(err, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
                if let conflict = osUsernameConflictError {
                    Label(conflict, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Step 3: 确认唤醒

struct Step3View: View {
    let dna: AgentDNA
    let displayName: String
    let osUsername: String

    var body: some View {
        VStack(spacing: 20) {
            Text(dna.emoji)
                .font(.system(size: 48))
                .padding(.top, 8)

            Text(L10n.k("views.awakening_wizard_view.about_to_awaken", fallback: "即将唤醒"))
                .font(.system(size: 15))
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                AwakeningInfoRow(label: L10n.k("views.awakening_wizard_view.role_prototype", fallback: "角色原型"), value: dna.name)
                Divider().padding(.horizontal, 4)
                AwakeningInfoRow(label: L10n.k("views.awakening_wizard_view.display_name", fallback: "显示名"), value: displayName)
                Divider().padding(.horizontal, 4)
                AwakeningInfoRow(label: L10n.k("views.awakening_wizard_view.os_username", fallback: "OS 用户名"), value: osUsername)
                Divider().padding(.horizontal, 4)
                AwakeningInfoRow(label: L10n.k("views.awakening_wizard_view.category", fallback: "分类"), value: dna.category)
            }
            .padding(.horizontal, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(L10n.k("views.awakening_wizard_view.confirm_to_awaken_locally", fallback: "确认后，TA 将在本地正式落户 🦞"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 信息行

struct AwakeningInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
