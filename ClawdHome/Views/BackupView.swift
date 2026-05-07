// ClawdHome/Views/BackupView.swift
// 分层备份管理：全局配置 + 每个 Shrimp 独立备份，支持定时备份和保留策略

import AppKit
import SwiftUI

struct BackupView: View {
    let users: [ManagedUser]

    @Environment(HelperClient.self) private var helperClient

    // 配置
    @State private var config: BackupConfig = .default
    @State private var configLoaded = false

    // 备份列表
    @State private var allBackups: [BackupListEntry] = []

    // 操作状态
    @State private var isBackingUp = false
    @State private var isRestoring = false
    @State private var progressText: String?
    @State private var errorMessage: String?

    // Shrimp 筛选
    @State private var selectedShrimpUser: String?

    // 恢复确认
    @State private var restoreTarget: BackupListEntry?
    @State private var backupBeforeRestore = true

    // 删除确认
    @State private var deleteTarget: BackupListEntry?

    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scheduleSection
                toolbarSection
                globalBackupsSection
                shrimpBackupsSection
            }
            .padding(20)
        }
        .navigationTitle(L10n.k("auto.backup_view.backups", fallback: "备份"))
        .task { await loadData() }
        .sheet(item: $restoreTarget) { entry in
            restoreConfirmSheet(entry)
        }
        .confirmationDialog(
            L10n.k("backup.delete.confirm.title", fallback: "删除备份？"),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = deleteTarget {
                Button(L10n.k("backup.delete.confirm.delete", fallback: "删除"), role: .destructive) {
                    Task { await performDelete(entry) }
                    deleteTarget = nil
                }
                Button(L10n.k("backup.delete.confirm.cancel", fallback: "取消"), role: .cancel) {
                    deleteTarget = nil
                }
            }
        } message: {
            if let entry = deleteTarget {
                Text(L10n.f("backup.delete.confirm.message", fallback: "%@\n此操作不可撤销。", entry.filename))
            }
        }
    }

    // MARK: - 定时备份设置

    @ViewBuilder
    private var scheduleSection: some View {
        GroupBox(L10n.k("backup.schedule.title", fallback: "定时备份")) {
            VStack(alignment: .leading, spacing: 10) {
                // 开关 + 间隔
                HStack {
                    Toggle(L10n.k("backup.schedule.enabled", fallback: "启用定时备份"), isOn: Binding(
                        get: { config.schedule.enabled },
                        set: { newVal in
                            config.schedule.enabled = newVal
                            Task { await saveConfig() }
                        }
                    ))

                    Spacer()

                    if config.schedule.enabled {
                        Text(L10n.k("backup.schedule.every", fallback: "每"))
                        Picker("", selection: Binding(
                            get: { config.schedule.intervalHours },
                            set: { newVal in
                                config.schedule.intervalHours = newVal
                                Task { await saveConfig() }
                            }
                        )) {
                            Text("6 " + L10n.k("backup.schedule.hours", fallback: "小时")).tag(6)
                            Text("12 " + L10n.k("backup.schedule.hours", fallback: "小时")).tag(12)
                            Text("24 " + L10n.k("backup.schedule.hours", fallback: "小时")).tag(24)
                            Text("48 " + L10n.k("backup.schedule.hours", fallback: "小时")).tag(48)
                            Text("72 " + L10n.k("backup.schedule.hours", fallback: "小时")).tag(72)
                        }
                        .frame(width: 120)
                    }
                }

                // 保留数
                HStack {
                    Text(L10n.k("backup.retention.label", fallback: "保留最近"))
                    Picker("", selection: Binding(
                        get: { config.retention.maxCount },
                        set: { newVal in
                            config.retention.maxCount = newVal
                            Task { await saveConfig() }
                        }
                    )) {
                        Text("3").tag(3)
                        Text("5").tag(5)
                        Text("7").tag(7)
                        Text("14").tag(14)
                        Text("30").tag(30)
                    }
                    .frame(width: 80)
                    Text(L10n.k("backup.retention.suffix", fallback: "个备份"))
                }

                // 备份目录
                HStack {
                    Text(config.backupDir)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(L10n.k("backup.dir.change", fallback: "更改...")) {
                        chooseBackupDir()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)

                    Button(L10n.k("backup.dir.reveal", fallback: "显示")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: config.backupDir))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }

                // 上次备份时间
                if let lastRun = config.schedule.lastRunAt,
                   let date = Self.iso8601.date(from: lastRun) {
                    let relative = relativeDateFormatter.localizedString(for: date, relativeTo: Date())
                    Text(L10n.f("backup.schedule.last_run", fallback: "上次备份：%@", relative))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 操作工具栏

    @ViewBuilder
    private var toolbarSection: some View {
        HStack(spacing: 12) {
            Button {
                Task { await performBackupAll() }
            } label: {
                if isBackingUp {
                    ProgressView().controlSize(.small)
                    Text(progressText ?? L10n.k("backup.action.backing_up", fallback: "备份中..."))
                } else {
                    Image(systemName: "arrow.clockwise.circle.fill")
                    Text(L10n.k("backup.action.backup_all", fallback: "一键备份全部"))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBackingUp || isRestoring || !helperClient.isConnected || users.isEmpty)

            Button {
                importBackupFile()
            } label: {
                Image(systemName: "square.and.arrow.down")
                Text(L10n.k("backup.action.import", fallback: "从文件导入..."))
            }
            .buttonStyle(.bordered)
            .disabled(isBackingUp || isRestoring)

            Spacer()

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - 全局配置备份

    @ViewBuilder
    private var globalBackupsSection: some View {
        let globalEntries = allBackups.filter { $0.backupType == "global" }

        GroupBox(L10n.f("backup.global.title", fallback: "全局配置备份（%@）", String(globalEntries.count))) {
            VStack(alignment: .leading, spacing: 0) {
                if globalEntries.isEmpty {
                    Text(L10n.k("backup.no_backups", fallback: "暂无备份"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(globalEntries.enumerated()), id: \.element.id) { idx, entry in
                        backupRow(entry)
                        if idx < globalEntries.count - 1 { Divider() }
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Shrimp 备份

    private var filteredShrimpEntries: [BackupListEntry] {
        if let selected = selectedShrimpUser {
            return allBackups.filter { $0.backupType == "shrimp" && $0.username == selected }
        }
        return allBackups.filter { $0.backupType == "shrimp" }
    }

    @ViewBuilder
    private var shrimpBackupsSection: some View {
        let shrimpEntries = filteredShrimpEntries

        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if shrimpEntries.isEmpty {
                    Text(L10n.k("backup.no_backups", fallback: "暂无备份"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(shrimpEntries.enumerated()), id: \.element.id) { idx, entry in
                        backupRow(entry)
                        if idx < shrimpEntries.count - 1 { Divider() }
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(L10n.f("backup.shrimp.title", fallback: "Shrimp 备份（%@）", String(shrimpEntries.count)))

                Spacer()

                Picker(L10n.k("backup.shrimp.filter", fallback: "筛选"), selection: $selectedShrimpUser) {
                    Text(L10n.k("backup.shrimp.all", fallback: "全部")).tag(nil as String?)
                    ForEach(users) { user in
                        Text("@\(user.username)").tag(user.username as String?)
                    }
                }
                .frame(width: 140)
            }
        }
    }

    // MARK: - 备份行

    @ViewBuilder
    private func backupRow(_ entry: BackupListEntry) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: entry.backupType == "global" ? "globe" : "person.crop.circle")
                .foregroundStyle(entry.backupType == "global" ? .blue : .orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.filename)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let username = entry.username {
                        Text("@\(username)")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.8), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(formattedSize(entry.fileSize))
                    if let date = Self.iso8601.date(from: entry.createdAt) {
                        Text("·")
                        Text(relativeDateFormatter.localizedString(for: date, relativeTo: Date()))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.k("backup.action.restore", fallback: "恢复")) {
                backupBeforeRestore = true
                restoreTarget = entry
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .font(.caption)
            .disabled(isBackingUp || isRestoring)

            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .disabled(isBackingUp || isRestoring)
        }
        .padding(.vertical, 6)
    }

    // MARK: - 恢复确认 Sheet

    @ViewBuilder
    private func restoreConfirmSheet(_ entry: BackupListEntry) -> some View {
        VStack(spacing: 16) {
            // 标题
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.title2)
                Text(L10n.k("backup.restore.confirm.title", fallback: "确认恢复"))
                    .font(.headline)
                Spacer()
            }

            // 描述
            VStack(alignment: .leading, spacing: 8) {
                if entry.backupType == "global" {
                    Text(L10n.k("backup.restore.confirm.global_desc", fallback: "即将恢复全局配置到备份版本。"))
                } else if let username = entry.username {
                    Text(L10n.f("backup.restore.confirm.shrimp_desc", fallback: "即将恢复 @%@ 到备份版本。\n网关将暂停服务直到恢复完成。", username))
                }

                if let date = Self.iso8601.date(from: entry.createdAt) {
                    Text(L10n.f("backup.restore.confirm.date", fallback: "备份时间：%@", date.formatted(date: .long, time: .shortened)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 恢复前备份选项（仅 Shrimp）
            if entry.backupType == "shrimp" {
                Toggle(L10n.k("backup.restore.confirm.backup_first", fallback: "恢复前先备份当前数据"), isOn: $backupBeforeRestore)
            }

            Divider()

            // 按钮
            HStack {
                Spacer()
                Button(L10n.k("backup.restore.confirm.cancel", fallback: "取消")) {
                    restoreTarget = nil
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button(L10n.k("backup.restore.confirm.confirm", fallback: "确认恢复")) {
                    let target = entry
                    restoreTarget = nil
                    Task { await performRestore(target) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - 操作

    private func loadData() async {
        do {
            config = try await helperClient.getBackupConfig()
            configLoaded = true
            allBackups = try await helperClient.listBackups(destinationDir: config.backupDir)
            if selectedShrimpUser == nil, let first = users.first {
                selectedShrimpUser = first.username
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveConfig() async {
        do {
            try await helperClient.setBackupConfig(config)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performBackupAll() async {
        isBackingUp = true
        progressText = L10n.k("backup.action.backing_up", fallback: "备份中...")
        errorMessage = nil
        do {
            try await helperClient.backupAllV2(destinationDir: config.backupDir)
            allBackups = try await helperClient.listBackups(destinationDir: config.backupDir)
        } catch {
            errorMessage = error.localizedDescription
        }
        isBackingUp = false
        progressText = nil
    }

    private func performRestore(_ entry: BackupListEntry) async {
        isRestoring = true
        errorMessage = nil
        do {
            if entry.backupType == "global" {
                try await helperClient.restoreGlobal(sourcePath: entry.filePath)
            } else if let username = entry.username {
                try await helperClient.restoreShrimp(
                    username: username,
                    sourcePath: entry.filePath,
                    backupBeforeRestore: backupBeforeRestore
                )
            }
            // 恢复后刷新列表
            allBackups = try await helperClient.listBackups(destinationDir: config.backupDir)
        } catch {
            errorMessage = error.localizedDescription
        }
        isRestoring = false
    }

    private func performDelete(_ entry: BackupListEntry) async {
        do {
            try await helperClient.deleteBackupFile(filePath: entry.filePath)
            allBackups = try await helperClient.listBackups(destinationDir: config.backupDir)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseBackupDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L10n.k("backup.dir.choose", fallback: "选择")
        panel.directoryURL = URL(fileURLWithPath: config.backupDir)
        if panel.runModal() == .OK, let url = panel.url {
            config.backupDir = url.path
            Task { await saveConfig() }
            Task { await loadData() }
        }
    }

    private func importBackupFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.gzip, .data]
        panel.prompt = L10n.k("backup.import.choose", fallback: "导入")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 根据文件名判断类型
        let filename = url.lastPathComponent
        if filename.hasPrefix("global-") {
            // 全局恢复确认
            let entry = BackupListEntry(
                filename: filename,
                filePath: url.path,
                fileSize: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                backupType: "global",
                username: nil
            )
            backupBeforeRestore = true
            restoreTarget = entry
        } else if filename.hasPrefix("shrimp-") {
            // 提取用户名
            let parts = filename.replacingOccurrences(of: "shrimp-", with: "").split(separator: "-")
            let username = parts.first.map(String.init) ?? ""
            let entry = BackupListEntry(
                filename: filename,
                filePath: url.path,
                fileSize: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                backupType: "shrimp",
                username: username
            )
            backupBeforeRestore = true
            restoreTarget = entry
        } else {
            errorMessage = L10n.k("backup.import.unknown_format", fallback: "无法识别的备份文件格式")
        }
    }

    // MARK: - 工具

    private func formattedSize(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1_048_576 { return String(format: "%.1f KB", b / 1024) }
        return String(format: "%.1f MB", b / 1_048_576)
    }
}
