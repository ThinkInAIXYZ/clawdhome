// ClawdHome/Views/AdoptTeamSheet.swift
// 领养团队弹窗：确认 Shrimp 名 → 创建 Shrimp → 写入待导入 agent 列表 → 进初始化向导

import SwiftUI

struct AdoptTeamSheet: View {
    let teamDNA: TeamDNA
    let existingUsers: [AwakeningExistingUser]
    let onDismiss: () -> Void

    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self) private var pool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var shrimpName: String = ""
    @State private var isCreating = false
    @State private var error: String?

    // username 从 shrimpName 自动派生
    private var derivedUsername: String {
        let base = shrimpName.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? String($0) : "" }
            .joined()
        if base.isEmpty || base.first?.isLetter != true {
            return "team_\(Int(Date().timeIntervalSince1970) % 10000)"
        }
        return String(base.prefix(30))
    }

    private var usernameConflict: Bool {
        pool.users.contains { $0.username.caseInsensitiveCompare(derivedUsername) == .orderedSame }
            || pool.users.contains { $0.fullName.caseInsensitiveCompare(shrimpName.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

    private var canCreate: Bool {
        !shrimpName.trimmingCharacters(in: .whitespaces).isEmpty && !usernameConflict && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack(spacing: 10) {
                Text(teamDNA.teamEmoji)
                    .font(.system(size: 32))
                VStack(alignment: .leading, spacing: 2) {
                    Text(teamDNA.teamName)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(L10n.k("adopt_team.subtitle", fallback: "一键组建专属团队"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 20)

            // 成员预览
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.k("adopt_team.members", fallback: "团队成员"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(teamDNA.members) { member in
                        HStack(spacing: 8) {
                            Text(member.emoji)
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(member.name)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(member.soul)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                            }
                            .frame(maxHeight: .infinity, alignment: .top)
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(.bottom, 20)

            Divider()
                .padding(.bottom, 16)

            // Shrimp 名称
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.k("adopt_team.shrimp_name", fallback: "工作区名称"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                TextField(L10n.k("adopt_team.shrimp_name.placeholder", fallback: "例如：我的创业班底"), text: $shrimpName)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 4) {
                    Text("@\(derivedUsername)")
                        .font(.caption)
                        .foregroundStyle(usernameConflict ? .red : .secondary)
                    if usernameConflict {
                        Text(L10n.k("adopt_team.shrimp_name.conflict", fallback: "名称已存在，请修改"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.bottom, 16)

            // 错误提示
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            // 按钮行
            HStack {
                Spacer()
                Button(L10n.k("common.action.cancel", fallback: "取消")) {
                    onDismiss()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await buildTeam() }
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.k("adopt_team.confirm", fallback: "组建团队"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(24)
        .onAppear {
            shrimpName = teamDNA.suggestedShrimpName
        }
    }

    // MARK: - 创建流程

    private func buildTeam() async {
        isCreating = true
        defer { isCreating = false }

        let fullName = shrimpName.trimmingCharacters(in: .whitespaces)
        let username = derivedUsername

        guard !fullName.isEmpty else {
            error = L10n.k("adopt_team.error.empty_name", fallback: "工作区名称不能为空")
            return
        }
        guard !usernameConflict else {
            error = L10n.k("adopt_team.error.conflict", fallback: "名称已存在，请换一个")
            return
        }

        do {
            // 1. 创建 macOS 用户
            let password = try UserPasswordStore.generateAndSave(for: username)
            do {
                try await helperClient.createUser(
                    username: username,
                    fullName: fullName,
                    password: password
                )
            } catch {
                self.error = error.localizedDescription
                return
            }

            // 2. 清理残留初始化进度
            try? await helperClient.saveInitState(username: username, json: "{}")

            // 3. 准备 workspace 目录
            let workspaceDir = ".openclaw/workspace"
            try? await helperClient.createDirectory(username: username, relativePath: workspaceDir)
            try? await helperClient.applySavedProxySettingsIfAny(username: username)

            // 4. 写入 pending_team_agents.json，供 gateway 就绪后批量导入
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let pendingData = try? encoder.encode(teamDNA.members) {
                try? await helperClient.writeFile(
                    username: username,
                    relativePath: "\(workspaceDir)/pending_team_agents.json",
                    data: pendingData
                )
            }

            // 5. 注入 TOOLS.md
            let toolsPath = "\(workspaceDir)/TOOLS.md"
            let toolsExists = (try? await helperClient.readFile(username: username, relativePath: toolsPath)) != nil
            if !toolsExists {
                try? await helperClient.writeFile(
                    username: username,
                    relativePath: toolsPath,
                    data: UserInitWizardView.defaultToolsContent.data(using: .utf8) ?? Data()
                )
            }

            // 6. 建立 shared/ 符号链接
            try? await helperClient.setupVault(username: username)

            // 7. 刷新列表并进初始化向导
            pool.loadUsers()
            pool.setDescription(teamDNA.teamName, for: username)
            pool.markNeedsOnboarding(username: username)
            NotificationCenter.default.post(name: .roleMarketAdoptionStarted, object: nil)
            openWindow(id: "user-init-wizard", value: username)

            onDismiss()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
