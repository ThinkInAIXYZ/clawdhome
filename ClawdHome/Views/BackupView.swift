// ClawdHome/Views/BackupView.swift
// 集中管理所有用户的 openclaw 数据备份

import AppKit
import SwiftUI

struct BackupView: View {
    let users: [ManagedUser]

    @Environment(HelperClient.self) private var helperClient
    @State private var backups: [BackupFile] = []
    @State private var isBackingUpAll = false
    @State private var backingUpUser: String?
    @State private var errorMessage: String?
    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // 备份位置
                GroupBox(L10n.k("auto.backup_view.backup", fallback: "备份位置")) {
                    HStack {
                        Text(backupDirectory.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(L10n.k("auto.backup_view.finder", fallback: "在 Finder 中显示")) {
                            NSWorkspace.shared.open(backupDirectory)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 备份操作
                GroupBox(L10n.k("auto.backup_view.backup", fallback: "备份操作")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button(isBackingUpAll ? L10n.k("auto.backup_view.backup", fallback: "备份中…") : L10n.k("auto.backup_view.backupuser", fallback: "备份全部用户")) {
                                Task { await backupAll() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isBackingUpAll || backingUpUser != nil
                                      || !helperClient.isConnected || users.isEmpty)
                            Spacer()
                        }

                        if !users.isEmpty {
                            Divider()
                            ForEach(users) { user in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(user.fullName.isEmpty ? user.username : user.fullName)
                                        Text("@\(user.username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if backingUpUser == user.username {
                                        ProgressView().scaleEffect(0.7)
                                            .frame(width: 50)
                                    } else {
                                        Button(L10n.k("auto.backup_view.backups", fallback: "备份")) {
                                            Task { await backupOne(user: user) }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)
                                        .disabled(isBackingUpAll || backingUpUser != nil
                                                  || !helperClient.isConnected)
                                    }
                                }
                            }
                        }

                        if let err = errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 备份记录
                GroupBox(L10n.f("views.backup_view.text_50f6634f", fallback: "备份记录（%@）", String(describing: backups.count))) {
                    VStack(alignment: .leading, spacing: 0) {
                        if backups.isEmpty {
                            Text(L10n.k("auto.backup_view.no_backups", fallback: "暂无备份"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(Array(backups.enumerated()), id: \.element.id) { idx, backup in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(backup.filename)
                                            .font(.system(.caption, design: .monospaced))
                                            .lineLimit(1)
                                        let relativeText = relativeDateFormatter.localizedString(for: backup.date, relativeTo: Date())
                                        Text(L10n.f("views.backup_view.text_f010b454", fallback: "%@ · %@", backup.formattedSize, relativeText))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(L10n.k("auto.backup_view.show", fallback: "显示")) {
                                        NSWorkspace.shared.activateFileViewerSelecting([backup.url])
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                }
                                .padding(.vertical, 6)
                                if idx < backups.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .navigationTitle(L10n.k("auto.backup_view.backups", fallback: "备份"))
        .task { refreshBackupList() }
    }

    // MARK: - 路径工具

    var backupDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/ClawdHome Backups")
    }

    func backupFileURL(for username: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let dateStr = formatter.string(from: Date())
        return backupDirectory
            .appendingPathComponent("openclaw-backup-\(username)-\(dateStr).tar.gz")
    }

    // MARK: - 操作

    private func refreshBackupList() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            backups = []
            return
        }
        backups = contents
            .filter { $0.pathExtension == "gz" }
            .compactMap { url -> BackupFile? in
                let res = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                return BackupFile(
                    url: url,
                    size: res?.fileSize ?? 0,
                    date: res?.creationDate ?? Date()
                )
            }
            .sorted { $0.date > $1.date }
    }

    private func backupAll() async {
        isBackingUpAll = true
        errorMessage = nil
        var failed: [String] = []
        try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        for user in users {
            let dest = backupFileURL(for: user.username)
            do {
                try await helperClient.backupUser(username: user.username, destinationPath: dest.path)
            } catch {
                failed.append("@\(user.username): \(error.localizedDescription)")
            }
        }
        errorMessage = failed.isEmpty ? nil : failed.joined(separator: "\n")
        refreshBackupList()
        isBackingUpAll = false
    }

    private func backupOne(user: ManagedUser) async {
        backingUpUser = user.username
        errorMessage = nil
        try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let dest = backupFileURL(for: user.username)
        do {
            try await helperClient.backupUser(username: user.username, destinationPath: dest.path)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshBackupList()
        backingUpUser = nil
    }
}

// MARK: - 数据模型

struct BackupFile: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int
    let date: Date

    var filename: String { url.lastPathComponent }

    var formattedSize: String {
        let b = Double(size)
        if b < 1024 { return "\(size) B" }
        if b < 1_048_576 { return String(format: "%.1f KB", b / 1024) }
        return String(format: "%.1f MB", b / 1_048_576)
    }
}
