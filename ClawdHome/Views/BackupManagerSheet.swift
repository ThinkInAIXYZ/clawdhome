// ClawdHome/Views/BackupManagerSheet.swift
// 历史备份管理：列出、删除该用户的所有 ClawdHome 备份

import SwiftUI

private struct BackupEntry: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let date: Date
    /// 是否为当前活跃的回退备份（删除后将失去回退能力）
    var isActiveRollback: Bool

    var filename: String { url.lastPathComponent }

    var formattedSize: String {
        let mb = Double(size) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(size) / 1024
        return String(format: "%.0f KB", kb)
    }
}

struct BackupManagerSheet: View {
    let username: String
    /// 当前活跃回退备份的路径（来自 UserDefaults）
    let activeBackupPath: String?
    /// 当活跃回退备份被删除时回调（让调用方清除 preUpgradeVersion/Path）
    var onActiveBackupDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [BackupEntry] = []
    @State private var confirmDeleteEntry: BackupEntry? = nil

    private var backupDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/ClawdHome Backups")
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Image(systemName: "archivebox")
                    .foregroundStyle(.tint)
                Text("备份管理").font(.headline)
                Text("@\(username)").foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    "暂无备份",
                    systemImage: "archivebox",
                    description: Text("升级 openclaw 时开启备份后，历史备份将显示在这里。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(entries) { entry in
                            BackupRow(entry: entry) {
                                confirmDeleteEntry = entry
                            }
                        }
                    }
                    .padding(16)
                }
            }

            Divider()

            HStack {
                Text("\(entries.count) 个备份")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 520, height: 380)
        .task { loadEntries() }
        .confirmationDialog(
            confirmDeleteEntry.map { _ in "删除备份？" } ?? "",
            isPresented: Binding(
                get: { confirmDeleteEntry != nil },
                set: { if !$0 { confirmDeleteEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = confirmDeleteEntry {
                Button("删除", role: .destructive) {
                    deleteEntry(entry)
                    confirmDeleteEntry = nil
                }
                Button("取消", role: .cancel) { confirmDeleteEntry = nil }
            }
        } message: {
            if let entry = confirmDeleteEntry {
                if entry.isActiveRollback {
                    Text("\(entry.filename)\n\n这是当前回退备份，删除后将无法回退到上一版本。")
                } else {
                    Text("\(entry.filename)\n\n此操作不可撤销。")
                }
            }
        }
    }

    // MARK: - 数据加载

    private func loadEntries() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else {
            entries = []
            return
        }

        let prefix = "pre-upgrade-\(username)-"
        entries = files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "gz" }
            .compactMap { url -> BackupEntry? in
                let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return BackupEntry(
                    url: url,
                    size: Int64(rv?.fileSize ?? 0),
                    date: rv?.contentModificationDate ?? Date(),
                    isActiveRollback: url.path == activeBackupPath
                )
            }
            .sorted { $0.date > $1.date }   // 最新的排前面
    }

    // MARK: - 删除

    private func deleteEntry(_ entry: BackupEntry) {
        try? FileManager.default.removeItem(at: entry.url)
        if entry.isActiveRollback {
            onActiveBackupDeleted()
        }
        loadEntries()
    }
}

// MARK: - 单行视图

private struct BackupRow: View {
    let entry: BackupEntry
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 图标
            Image(systemName: entry.isActiveRollback ? "archivebox.fill" : "archivebox")
                .foregroundStyle(entry.isActiveRollback ? Color.accentColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.filename)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isActiveRollback {
                        Text("回退用")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
                HStack(spacing: 8) {
                    Text(entry.date, style: .date)
                    Text(entry.date, style: .time)
                    Text("·")
                    Text(entry.formattedSize)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
    }
}
