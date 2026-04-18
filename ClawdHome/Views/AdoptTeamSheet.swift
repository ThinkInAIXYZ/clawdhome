// ClawdHome/Views/AdoptTeamSheet.swift
// 领养团队弹窗：确认 Shrimp 名 → 创建 Shrimp → 暂存团队草稿 → 进初始化向导
// ⚠️ DEPRECATED (v2): 团队初始化入口已集成到 ShrimpInitWizardV2（模板选择步骤）。
// 本文件保留在 git 历史中，不删除。

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
    @State private var usernameInput: String = ""
    @State private var isCreating = false
    @State private var error: String?

    // 实例 ID 优先使用可编辑输入；为空时回退到 shrimpName 自动派生
    private var derivedUsername: String {
        let preferred = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty {
            return ASCIIIdentifier.username(from: preferred, fallbackPrefix: "team", maxLength: 30)
        }
        return ASCIIIdentifier.username(from: shrimpName, fallbackPrefix: "team", maxLength: 30)
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
                                .frame(width: 28, alignment: .center)
                            VStack(alignment: .leading, spacing: 2) {
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
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
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

                Text(L10n.k("adopt_team.instance_id", fallback: "实例 ID（@ID，可修改）"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                TextField(L10n.k("adopt_team.instance_id.placeholder", fallback: "例如：startup_core_team"), text: $usernameInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

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
            if shrimpName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                shrimpName = teamDNA.teamName
            }
            if usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                usernameInput = teamDNA.suggestedInstanceID
            }
        }
    }

    // MARK: - 创建流程

    private func buildTeam() async {
        isCreating = true
        defer { isCreating = false }

        let fullName = shrimpName.trimmingCharacters(in: .whitespacesAndNewlines)
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

            // 4. 注入 TOOLS.md
            let toolsPath = "\(workspaceDir)/TOOLS.md"
            let toolsExists = (try? await helperClient.readFile(username: username, relativePath: toolsPath)) != nil
            if !toolsExists {
                try? await helperClient.writeFile(
                    username: username,
                    relativePath: toolsPath,
                    data: UserInitWizardView.defaultToolsContent.data(using: .utf8) ?? Data()
                )
            }

            // 5. 建立 shared/ 符号链接
            try? await helperClient.setupVault(username: username)

            // 6. 暂存团队草稿（由 v2 初始化向导一次性消费）
            pool.stageInitTeam(teamDNA, for: username)

            // 7. 刷新列表并进入初始化向导
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
