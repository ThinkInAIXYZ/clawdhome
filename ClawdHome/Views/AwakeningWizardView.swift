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
    var onAwaken: ((String, String, String, String, String, String) async throws -> Void)? = nil

    @State private var step = 1
    @State private var displayName = ""
    @State private var osUsername = ""
    @State private var osUsernameError: String? = nil
    @State private var displayNameError: String? = nil
    @State private var osUsernameConflictError: String? = nil
    @State private var submitError: String? = nil
    @State private var isSubmitting = false

    @State private var editedSoul: String = ""
    @State private var editedIdentity: String = ""
    @State private var editedUser: String = ""

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: step, total: 3)
                .padding(.top, 20)
                .padding(.bottom, 16)

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

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
                    .padding(.top, 1)
                Text(
                    L10n.k(
                        "views.awakening_wizard_view.privacy_banner",
                        fallback: "\u{60A8}\u{6B63}\u{5728}\u{5C06}\u{6B64}\u{6570}\u{5B57}\u{751F}\u{547D}\u{57FA}\u{56E0}\u{4ECE}\u{4E91}\u{7AEF}\u{4E0B}\u{8F7D}\u{5230}\u{60A8}\u{7684}\u{672C}\u{5730}\u{8BBE}\u{5907}\u{3002}\u{6240}\u{6709}\u{540E}\u{7EED}\u{6570}\u{636E}\u{4EA4}\u{4E92}\u{3001}\u{77E5}\u{8BC6}\u{5E93}\u{6784}\u{5EFA}\u{90FD}\u{5C06}\u{53D1}\u{751F}\u{5728}\u{60A8}\u{7684}\u{7269}\u{7406}\u{8282}\u{70B9}\u{5185}\u{FF0C}\u{7EDD}\u{5BF9}\u{9690}\u{79C1}\u{FF0C}\u{4E91}\u{7AEF}\u{9694}\u{79BB}\u{3002}"
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
                        Text(L10n.k("views.awakening_wizard_view.fix_and_retry_hint", fallback: "\u{8BF7}\u{70B9}\u{51FB}\u{201C}\u{2190} \u{8FD4}\u{56DE}\u{201D}\u{4FEE}\u{6539}\u{540E}\u{91CD}\u{8BD5}\u{3002}"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(L10n.k("views.awakening_wizard_view.back_to_edit", fallback: "\u{8FD4}\u{56DE}\u{4FEE}\u{6539}")) {
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

            HStack(spacing: 12) {
                if step > 1 {
                    Button(L10n.k("views.awakening_wizard_view.back", fallback: "\u{2190} \u{8FD4}\u{56DE}")) { step -= 1 }
                        .buttonStyle(.bordered)
                        .disabled(isSubmitting)
                } else {
                    Button(L10n.k("views.awakening_wizard_view.cancel", fallback: "\u{53D6}\u{6D88}")) {
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
                            ? L10n.k("views.awakening_wizard_view.awakening", fallback: "\u{5524}\u{9192}\u{4E2D}\u{2026}")
                            : L10n.k("views.awakening_wizard_view.awaken_now", fallback: "\u{6B63}\u{5F0F}\u{5524}\u{9192} \u{1F99E}")
                        )
                        : L10n.k("views.awakening_wizard_view.next", fallback: "\u{4E0B}\u{4E00}\u{6B65} \u{2192}")
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
            editedSoul     = dna.fileSoul     ?? ""
            editedIdentity = dna.fileIdentity ?? ""
            editedUser     = dna.fileUser     ?? ""
            if let suggested = dna.suggestedUsername, !suggested.isEmpty {
                osUsername = suggested
            }
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
                        Text(L10n.k("views.awakening_wizard_view.creating_shrimp_and_starting_wizard", fallback: "\u{6B63}\u{5728}\u{521B}\u{5EFA}\u{867E}\u{5E76}\u{542F}\u{52A8}\u{521D}\u{59CB}\u{5316}\u{5411}\u{5BFC}\u{2026}"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(L10n.k("views.awakening_wizard_view.usually_takes_3_8_seconds", fallback: "\u{901A}\u{5E38}\u{9700}\u{8981} 3-8 \u{79D2}\u{FF0C}\u{8BF7}\u{7A0D}\u{5019}"))
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
                displayNameError = L10n.k("views.awakening.display_name_empty", fallback: "\u{663E}\u{793A}\u{540D}\u{4E0D}\u{80FD}\u{4E3A}\u{7A7A}")
                return
            }
            guard isValidOSUsername(osUsername) else {
                osUsernameError = L10n.k("views.awakening_wizard_view.os_username_error", fallback: "\u{4EE5}\u{5B57}\u{6BCD}\u{5F00}\u{5934}\u{FF0C}\u{53EA}\u{5141}\u{8BB8}\u{5B57}\u{6BCD}\u{3001}\u{6570}\u{5B57}\u{3001}\u{4E0B}\u{5212}\u{7EBF}")
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
            osUsernameError = L10n.k("views.awakening_wizard_view.os_username_error", fallback: "\u{4EE5}\u{5B57}\u{6BCD}\u{5F00}\u{5934}\u{FF0C}\u{53EA}\u{5141}\u{8BB8}\u{5B57}\u{6BCD}\u{3001}\u{6570}\u{5B57}\u{3001}\u{4E0B}\u{5212}\u{7EBF}")
            osUsernameConflictError = nil
        }
    }

    private func conflictErrorForDisplayName(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if existingUsers.contains(where: { $0.fullName.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return L10n.f("views.awakening.display_name_taken", fallback: "\u{663E}\u{793A}\u{540D} %@ \u{5DF2}\u{88AB}\u{4F7F}\u{7528}\u{FF0C}\u{8BF7}\u{6362}\u{4E00}\u{4E2A}\u{540D}\u{5B57}", normalized)
        }
        return nil
    }

    private func conflictErrorForUsername(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if existingUsers.contains(where: { $0.username.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return L10n.f("views.awakening.username_exists", fallback: "\u{7528}\u{6237}\u{540D} @%@ \u{5DF2}\u{5B58}\u{5728}\u{FF0C}\u{8BF7}\u{6362}\u{4E00}\u{4E2A}\u{518D}\u{8BD5}", normalized)
        }
        return nil
    }
}

// MARK: - StepIndicator

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

// MARK: - Step 1

struct Step1View: View {
    let dna: AgentDNA
    @Binding var editedSoul: String
    @Binding var editedIdentity: String
    @Binding var editedUser: String

    var body: some View {
        VStack(spacing: 0) {
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

            VStack(spacing: 8) {
                DNAFileEditor(
                    icon: "heart.text.square.fill",
                    iconColor: .pink,
                    title: L10n.k("views.awakening_wizard_view.soul_title", fallback: "\u{6838}\u{5FC3}\u{4EF7}\u{503C}\u{89C2}"),
                    subtitle: "SOUL",
                    text: $editedSoul
                )
                DNAFileEditor(
                    icon: "person.text.rectangle.fill",
                    iconColor: .purple,
                    title: L10n.k("views.awakening_wizard_view.identity_title", fallback: "\u{8EAB}\u{4EFD}\u{8BBE}\u{5B9A}"),
                    subtitle: "IDENTITY",
                    text: $editedIdentity
                )
                DNAFileEditor(
                    icon: "person.crop.circle.fill",
                    iconColor: .orange,
                    title: L10n.k("views.awakening_wizard_view.user_title", fallback: "\u{6211}\u{7684}\u{753B}\u{50CF}"),
                    subtitle: "USER",
                    text: $editedUser
                )
            }
        }
    }
}

// MARK: - DNAFileEditor

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

            if isExpanded {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(8)
                    .scrollContentBackground(.hidden)
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

// MARK: - Step 2

struct Step2View: View {
    @Binding var displayName: String
    @Binding var displayNameError: String?
    @Binding var osUsername: String
    @Binding var osUsernameError: String?
    @Binding var osUsernameConflictError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.k("views.awakening_wizard_view.name_your_companion", fallback: "\u{7ED9} TA \u{8D77}\u{4E2A}\u{540D}\u{5B57}"))
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.k("views.awakening_wizard_view.display_name", fallback: "\u{663E}\u{793A}\u{540D}"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(L10n.k("views.awakening_wizard_view.role_display_name", fallback: "\u{89D2}\u{8272}\u{663E}\u{793A}\u{540D}\u{79F0}"), text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                if let err = displayNameError {
                    Label(err, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.k("views.awakening_wizard_view.independent_macos_username", fallback: "\u{72EC}\u{7ACB} macOS \u{7528}\u{6237}\u{540D}\u{FF08}\u{5B89}\u{5168}\u{9694}\u{79BB}\u{FF09}"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(L10n.k("views.awakening_wizard_view.system_username", fallback: "\u{7CFB}\u{7EDF}\u{7528}\u{6237}\u{540D}"), text: $osUsername)
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

// MARK: - Step 3

struct Step3View: View {
    let dna: AgentDNA
    let displayName: String
    let osUsername: String

    var body: some View {
        VStack(spacing: 20) {
            Text(dna.emoji)
                .font(.system(size: 48))
                .padding(.top, 8)

            Text(L10n.k("views.awakening_wizard_view.about_to_awaken", fallback: "\u{5373}\u{5C06}\u{5524}\u{9192}"))
                .font(.system(size: 15))
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                AwakeningInfoRow(label: L10n.k("views.awakening_wizard_view.role_prototype", fallback: "\u{89D2}\u{8272}\u{539F}\u{578B}"), value: dna.name)
                Divider().padding(.horizontal, 4)
                AwakeningInfoRow(label: L10n.k("views.awakening_wizard_view.display_name", fallback: "\u{663E}\u{793A}\u{540D}"), value: displayName)
                Divider().padding(.horizontal, 4)
                AwakeningInfoRow(label: L10n.k("views.awakening_wizard_view.os_username", fallback: "OS \u{7528}\u{6237}\u{540D}"), value: osUsername)
                Divider().padding(.horizontal, 4)
                AwakeningInfoRow(label: L10n.k("views.awakening_wizard_view.category", fallback: "\u{5206}\u{7C7B}"), value: dna.category)
            }
            .padding(.horizontal, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(L10n.k("views.awakening_wizard_view.confirm_to_awaken_locally", fallback: "\u{786E}\u{8BA4}\u{540E}\u{FF0C}TA \u{5C06}\u{5728}\u{672C}\u{5730}\u{6B63}\u{5F0F}\u{843D}\u{6237} \u{1F99E}"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - AwakeningInfoRow

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
