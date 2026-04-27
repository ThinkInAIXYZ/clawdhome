// ClawdHome/Views/VaultFilesView.swift
// 安全文件夹全局视图：以卡片网格展示每只虾的 vault 和公共文件夹

import SwiftUI
import AppKit

struct VaultFilesView: View {
    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self) private var pool

    @State private var migratingUsernames: Set<String> = []
    @State private var errorMessage: String?

    private let publicPath = "/Users/Shared/ClawdHome/public"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                cardGrid
            }
            .padding(20)
        }
        .navigationTitle(L10n.k("vault_files.title", fallback: "文件共享"))
        .alert(
            L10n.k("vault_files.error_title", fallback: "操作失败"),
            isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            actions: { Button("OK") { errorMessage = nil } },
            message: { if let msg = errorMessage { Text(msg) } }
        )
        .task { await ensureToolsForAllShrimps() }
    }

    // MARK: - 头部

    private var header: some View {
        Text(L10n.k("vault_files.subtitle", fallback: "专属安全空间 — 虾之间数据互不可见，您决定每只虾能接触哪些文件。产出物一键在 Finder 中查阅，文件交换尽在掌握"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: - 卡片网格

    private var cardGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 14)],
            spacing: 14
        ) {
            // 每只虾的安全文件夹
            ForEach(shrimpUsers) { user in
                VaultCard(
                    title: L10n.f("views.vault_files.exclusive_title", fallback: "%@_专属", user.fullName),
                    icon: "🦞",
                    iconColor: .blue,
                    badge: vaultBadge(for: user.username),
                    isMigrating: migratingUsernames.contains(user.username)
                ) {
                    Task { await openVault(username: user.username) }
                }
            }

            // 公共文件夹
            VaultCard(
                title: L10n.k("vault_files.public_folder", fallback: "通用全局知识库"),
                icon: "🌐",
                iconColor: .green,
                badge: publicBadge,
                isMigrating: false
            ) {
                Task { await openPublicFolder() }
            }
        }
    }

    // MARK: - 数据

    private var shrimpUsers: [ManagedUser] {
        pool.users.filter { !$0.isAdmin }
    }

    private var publicBadge: String {
        guard FileManager.default.fileExists(atPath: publicPath),
              let items = try? FileManager.default.contentsOfDirectory(atPath: publicPath) else {
            return L10n.f("views.vault_files.item_count", fallback: "%d 个项目", 0)
        }
        let count = items.filter { !$0.hasPrefix(".") }.count
        return L10n.f("views.vault_files.item_count", fallback: "%d 个项目", count)
    }

    private func vaultBadge(for username: String) -> String {
        let vaultPath = "/Users/Shared/ClawdHome/vaults/\(username)"
        guard FileManager.default.fileExists(atPath: vaultPath),
              let items = try? FileManager.default.contentsOfDirectory(atPath: vaultPath) else {
            return L10n.f("views.vault_files.item_count", fallback: "%d 个项目", 0)
        }
        let count = items.filter { !$0.hasPrefix(".") }.count
        return L10n.f("views.vault_files.item_count", fallback: "%d 个项目", count)
    }

    // MARK: - 操作

    private func openVault(username: String) async {
        let vaultPath = "/Users/Shared/ClawdHome/vaults/\(username)"
        if !FileManager.default.fileExists(atPath: vaultPath) {
            migratingUsernames.insert(username)
            defer { migratingUsernames.remove(username) }
            do {
                try await helperClient.setupVault(username: username)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        openInFinder(path: vaultPath)
    }

    private func openPublicFolder() async {
        if !FileManager.default.fileExists(atPath: publicPath) {
            if let first = shrimpUsers.first {
                try? await helperClient.setupVault(username: first.username)
            }
        }
        openInFinder(path: publicPath)
    }

    /// 共享文件夹指引的标记，用于判断 TOOLS.md 中是否已包含
    private static let sharedFolderMarker = "~/clawdhome_shared/"

    private let logger = AppLogger.shared

    /// 为所有老虾补全 TOOLS.md 和 vault 目录（后台静默执行）
    private func ensureToolsForAllShrimps() async {
        let toolsRelPath = ".openclaw/workspace/TOOLS.md"
        logger.log("[文件共享] 开始检查 \(shrimpUsers.count) 只虾的 TOOLS.md 和 vault 状态")
        for user in shrimpUsers {
            // 确保 workspace 目录存在
            try? await helperClient.createDirectory(username: user.username, relativePath: ".openclaw/workspace")

            let existingData = try? await helperClient.readFile(username: user.username, relativePath: toolsRelPath)
            let existingContent = existingData.flatMap { String(data: $0, encoding: .utf8) } ?? ""

            if !existingContent.contains(Self.sharedFolderMarker) {
                logger.log("[文件共享] @\(user.username) TOOLS.md 缺少共享文件夹指引，追加写入")
                // 不存在或不含共享文件夹指引 → 追加
                let newContent = existingContent.isEmpty
                    ? defaultToolsContent
                    : existingContent + "\n\n" + defaultToolsContent
                try? await helperClient.writeFile(
                    username: user.username,
                    relativePath: toolsRelPath,
                    data: newContent.data(using: .utf8) ?? Data()
                )
                try? await helperClient.initPersonaGitRepo(username: user.username)
                try? await helperClient.commitPersonaFile(username: user.username, filename: "TOOLS.md", message: "Add shared folder guidance")
                logger.log("[文件共享] @\(user.username) TOOLS.md 已更新并提交")
            }

            // 确保 vault 目录和符号链接存在
            do {
                try await helperClient.setupVault(username: user.username)
            } catch {
                logger.log("[文件共享] @\(user.username) setupVault 失败: \(error.localizedDescription)", level: .warn)
            }
        }
        logger.log("[文件共享] 全部虾检查完成")
    }

    private func openInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }
}

// MARK: - 文件夹卡片

private struct VaultCard: View {
    let title: String
    let icon: String
    let iconColor: Color
    let badge: String?
    let isMigrating: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(iconColor.opacity(0.7))
                    Text(icon)
                        .font(.system(size: 18))
                        .offset(y: -2)
                }
                .frame(height: 50)

                if isMigrating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    // 状态指示点
                    Circle()
                        .fill(Color.green.opacity(0.8))
                        .frame(width: 6, height: 6)
                }

                Text(title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                if let badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 140)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.accentColor.opacity(0.06) : Color(.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isHovered ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(isMigrating)
    }
}
