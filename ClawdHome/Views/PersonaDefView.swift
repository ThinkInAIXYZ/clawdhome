// ClawdHome/Views/PersonaDefView.swift
// 角色定义 Tab — 分栏式多文件编辑器
//
// 视图层级：
//   CharacterDefTabView（顶层）
//     ├── PersonaFileSidebarView（左侧 190pt 文件列表）
//     └── PersonaEditorAreaView（右侧：编辑器 + 备忘录 + 历史面板）
//
// 数据流：
//   读文件 → helperClient.readFile
//   写文件 → helperClient.writeFile → helperClient.commitPersonaFile
//   历史 → helperClient.getPersonaFileHistory / getPersonaFileDiff
//   回滚 → helperClient.restorePersonaFileToCommit → readFile 重新加载

import SwiftUI

// MARK: - PersonaFile 枚举

enum PersonaFile: String, CaseIterable, Identifiable {
    case soul     = "SOUL.md"
    case identity = "IDENTITY.md"
    case agents   = "AGENTS.md"
    case tools    = "TOOLS.md"
    case memory   = "MEMORY.md"
    case user     = "USER.md"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .soul:     return "💫"
        case .identity: return "🪪"
        case .agents:   return "🤖"
        case .tools:    return "🔧"
        case .memory:   return "🗂️"
        case .user:     return "👤"
        }
    }

    var description: String {
        switch self {
        case .soul:     return L10n.k("persona.file.soul.desc",     fallback: "核心价值观 · 行为准则")
        case .identity: return L10n.k("persona.file.identity.desc", fallback: "说话风格 · 身份设定")
        case .agents:   return L10n.k("persona.file.agents.desc",   fallback: "操作指令 · 记忆管理")
        case .tools:    return L10n.k("persona.file.tools.desc",    fallback: "可调用的 API 和工具")
        case .memory:   return L10n.k("persona.file.memory.desc",   fallback: "记住的重要事实")
        case .user:     return L10n.k("persona.file.user.desc",     fallback: "用户认知 · 偏好设定")
        }
    }

    /// 相对于 Shrimp home 的文件路径
    var relPath: String { ".openclaw/workspace/\(rawValue)" }
}

// MARK: - 选中项模型（静态角色文件 or 记忆日志）

enum PersonaSelection: Hashable {
    case file(PersonaFile)
    case memoryLog(String)  // filename, e.g. "2024-03-15.md"

    var isMemoryLog: Bool {
        if case .memoryLog = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .file(let f): return f.rawValue
        case .memoryLog(let name): return name
        }
    }

    var relPath: String {
        switch self {
        case .file(let f): return f.relPath
        case .memoryLog(let name): return ".openclaw/workspace/memory/\(name)"
        }
    }
}

// MARK: - CharacterDefTabView（顶层入口）

struct CharacterDefTabView: View {
    let username: String
    var agentId: String? = nil       // nil = default agent（使用默认 workspace）
    var agentLabel: String? = nil    // 显示用的标签（如 "🎯 项目经理"）

    @Environment(HelperClient.self) private var helperClient

    // 编辑器状态
    @State private var selection: PersonaSelection = .file(.soul)
    @State private var editorContents: [PersonaFile: String] = [:]   // 内存中的编辑内容
    @State private var savedContents: [PersonaFile: String] = [:]    // 最后一次保存到磁盘的内容
    @State private var existsOnDisk: [PersonaFile: Bool] = [:]        // 文件是否存在

    // 记忆日志
    @State private var memoryLogFiles: [String] = []                  // memory/ 目录下的文件名列表
    @State private var memoryLogContent: String = ""                  // 当前选中日志的内容
    @State private var memoryLogExpanded: Bool = false                // 侧边栏展开状态
    @State private var isLoading: Bool = false
    @State private var isSaving: Bool = false

    // git 状态
    @State private var gitInitFailed: Bool = false
    @State private var lastCommitFailed: Bool = false

    // 切换文件时的脏检查 Sheet
    @State private var pendingSwitch: PersonaSelection? = nil
    @State private var showDirtySheet: Bool = false

    // 历史刷新令牌（每次保存成功后 +1，PersonaHistoryView 监听此值自动重载）
    @State private var historyRefreshToken: Int = 0

    // 保存成功 Toast（含行变化摘要）
    @State private var saveToast: String? = nil

    // 回滚后的 Toast
    @State private var showRestoreToast: Bool = false

    // 读取错误（离线等）
    @State private var loadError: String? = nil

    // 删除当前角色
    @State private var showDeleteAgentConfirm: Bool = false

    /// 是否为非默认 agent
    private var isNonDefaultAgent: Bool {
        if let id = agentId, id != "main", !id.isEmpty { return true }
        return false
    }

    /// 根据 agentId 计算文件的相对路径
    private func relPath(for file: PersonaFile) -> String {
        if let agentId = agentId, agentId != "main", !agentId.isEmpty {
            return ".openclaw/workspace-\(agentId)/\(file.rawValue)"
        }
        return file.relPath  // 默认路径
    }

    /// 根据 agentId 计算记忆日志目录路径
    private var memoryLogDirPath: String {
        if let agentId = agentId, agentId != "main", !agentId.isEmpty {
            return ".openclaw/workspace-\(agentId)/memory"
        }
        return ".openclaw/workspace/memory"
    }

    /// 根据 agentId 计算记忆日志文件路径
    private func memoryLogRelPath(_ name: String) -> String {
        return "\(memoryLogDirPath)/\(name)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Agent 标签标题
            if let label = agentLabel {
                HStack(spacing: 6) {
                    Text(L10n.f("persona.agent.header", fallback: "角色定义 — %@", label))
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
                Divider()
            }

            HSplitView {
                // 左侧侧边栏
                PersonaFileSidebarView(
                    selection: $selection,
                    editorContents: editorContents,
                    savedContents: savedContents,
                    existsOnDisk: existsOnDisk,
                    memoryLogFiles: memoryLogFiles,
                    memoryLogExpanded: $memoryLogExpanded,
                    onSelect: { sel in handleSelect(sel) }
                )
                .frame(minWidth: 160, idealWidth: 190, maxWidth: 220)

                // 右侧主区域
                switch selection {
                case .file(let file):
                    PersonaEditorAreaView(
                        username: username,
                        selectedFile: file,
                        relPath: relPath(for: file),
                        content: Binding(
                            get: { editorContents[file] ?? "" },
                            set: { editorContents[file] = $0 }
                        ),
                        isLoading: isLoading,
                        isSaving: isSaving,
                        isDirty: isDirty(file),
                        fileExistsOnDisk: existsOnDisk[file] ?? false,
                        gitInitFailed: gitInitFailed || isNonDefaultAgent,
                        lastCommitFailed: lastCommitFailed,
                        loadError: loadError,
                        historyRefreshToken: historyRefreshToken,
                        onSave: { Task { await save(file: file) } },
                        onDiscard: { discardEdits(file: file) },
                        onRestored: { Task { await reloadAfterRestore() } }
                    )
                case .memoryLog(let name):
                    PersonaMemoryLogView(
                        filename: name,
                        content: memoryLogContent,
                        isLoading: isLoading,
                        loadError: loadError
                    )
                }
            }

            // 删除当前角色（仅对非默认 agent 显示）
            if isNonDefaultAgent {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Button(role: .destructive) {
                        showDeleteAgentConfirm = true
                    } label: {
                        Label(L10n.k("persona.agent.delete", fallback: "删除当前角色"), systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)

                    Text(L10n.k("persona.agent.delete.hint", fallback: "删除后将清除该角色的 workspace、会话历史和渠道绑定"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .task {
            await initGitAndLoadFirstFile()
        }
        // 切换文件时的脏检查
        .confirmationDialog(
            L10n.k("persona.dirty.title", fallback: "保存对 \(selection.displayName) 的更改？"),
            isPresented: $showDirtySheet,
            titleVisibility: .visible
        ) {
            if case .file(let currentFile) = selection {
                Button(L10n.k("persona.dirty.save", fallback: "保存")) {
                    Task {
                        await save(file: currentFile)
                        if let target = pendingSwitch {
                            await switchTo(target)
                        }
                    }
                }
                Button(L10n.k("persona.dirty.discard", fallback: "丢弃"), role: .destructive) {
                    discardEdits(file: currentFile)
                    if let target = pendingSwitch {
                        Task { await switchTo(target) }
                    }
                }
            }
            Button(L10n.k("persona.dirty.cancel", fallback: "取消"), role: .cancel) {
                pendingSwitch = nil
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                if let msg = saveToast {
                    Text(msg)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if showRestoreToast {
                    Text(L10n.k("persona.restore.toast", fallback: "已回滚并重新加载"))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.bottom, 20)
        }
        .animation(.easeInOut(duration: 0.3), value: saveToast)
        .animation(.easeInOut(duration: 0.3), value: showRestoreToast)
        .alert(L10n.k("persona.agent.delete.alert.title", fallback: "删除角色"), isPresented: $showDeleteAgentConfirm) {
            Button(L10n.k("persona.agent.delete.alert.cancel", fallback: "取消"), role: .cancel) {}
            Button(L10n.k("persona.agent.delete.alert.confirm", fallback: "确认删除"), role: .destructive) {
                Task { await deleteCurrentAgent() }
            }
        } message: {
            Text(L10n.k("persona.agent.delete.alert.message", fallback: "确定要删除此角色吗？此操作不可撤销。"))
        }
    }

    // MARK: - 私有方法

    private func isDirty(_ file: PersonaFile) -> Bool {
        let editor = editorContents[file] ?? ""
        let saved  = savedContents[file] ?? ""
        return editor != saved
    }

    private func handleSelect(_ sel: PersonaSelection) {
        guard sel != selection else { return }
        // 只有当前选中的是角色文件且有未保存修改时才需要确认
        if case .file(let currentFile) = selection, isDirty(currentFile) {
            pendingSwitch = sel
            showDirtySheet = true
        } else {
            Task { await switchTo(sel) }
        }
    }

    private func switchTo(_ sel: PersonaSelection) async {
        pendingSwitch = nil
        selection = sel
        switch sel {
        case .file(let file):
            await loadFile(file)
        case .memoryLog(let name):
            await loadMemoryLog(name)
        }
    }

    private func initGitAndLoadFirstFile() async {
        // 非默认 agent 跳过 git 初始化（独立 workspace 暂不支持 git 历史）
        if !isNonDefaultAgent {
            do {
                try await helperClient.initPersonaGitRepo(username: username)
            } catch {
                gitInitFailed = true
            }
        }
        await loadFile(.soul)
        // 同时加载记忆日志列表
        await loadMemoryLogList()
    }

    private func loadMemoryLogList() async {
        do {
            let entries = try await helperClient.listDirectory(
                username: username,
                relativePath: memoryLogDirPath
            )
            memoryLogFiles = entries
                .filter { !$0.isDirectory && $0.name.hasSuffix(".md") }
                .map(\.name)
                .sorted(by: >) // 最新日期在前
        } catch {
            memoryLogFiles = []
        }
    }

    private func loadMemoryLog(_ name: String) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let data = try await helperClient.readFile(
                username: username,
                relativePath: memoryLogRelPath(name)
            )
            memoryLogContent = String(data: data, encoding: .utf8) ?? ""
        } catch {
            let msg = error.localizedDescription
            if msg.contains("No such file") || msg.contains("not found") || msg.contains("不存在") {
                memoryLogContent = ""
                loadError = nil
            } else {
                loadError = L10n.k("persona.load.offline", fallback: "虾未运行，无法读取文件")
            }
        }
    }

    private func loadFile(_ file: PersonaFile) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let data = try await helperClient.readFile(username: username, relativePath: relPath(for: file))
            let text = String(data: data, encoding: .utf8) ?? ""
            editorContents[file] = text
            savedContents[file] = text
            existsOnDisk[file] = true
        } catch {
            let msg = error.localizedDescription
            if msg.contains("No such file") || msg.contains("not found") || msg.contains("不存在") {
                // 文件不存在：空编辑器，可创建
                editorContents[file] = editorContents[file] ?? ""
                savedContents[file] = savedContents[file] ?? ""
                existsOnDisk[file] = false
                loadError = nil
            } else {
                // 虾离线或其他通信失败
                loadError = L10n.k("persona.load.offline", fallback: "虾未运行，无法读取文件")
            }
        }
    }

    private func save(file: PersonaFile) async {
        isSaving = true
        lastCommitFailed = false
        defer { isSaving = false }

        let newContent = editorContents[file] ?? ""
        let oldContent = savedContents[file] ?? ""
        guard let data = newContent.data(using: .utf8) else { return }

        // 保存前计算行变化（用于 toast 提示）
        let lineDiff = computeLineDiff(old: oldContent, new: newContent)

        do {
            // 1. 写文件
            try await helperClient.writeFile(username: username, relativePath: relPath(for: file), data: data)
            savedContents[file] = newContent
            existsOnDisk[file] = true

            // 2. git commit（非默认 agent 跳过，静默降级，写文件已成功）
            if !isNonDefaultAgent {
                let isoDate = ISO8601DateFormatter().string(from: Date())
                let commitMsg = L10n.f("views.persona_def.commit_message", fallback: "更新 %@ — %@", file.rawValue, isoDate)
                do {
                    try await helperClient.commitPersonaFile(username: username, filename: file.rawValue, message: commitMsg)
                    // 刷新历史面板
                    historyRefreshToken += 1
                } catch {
                    lastCommitFailed = true
                }
            }

            // 显示保存成功 toast
            showSaveToast(file: file, diff: lineDiff)
        } catch {
            // 写文件失败不做 toast，编辑区 banner 会提示
        }
    }

    /// 计算两段文本的行级增删数
    private func computeLineDiff(old: String, new: String) -> (added: Int, removed: Int) {
        let oldLines = Set(old.components(separatedBy: "\n"))
        let newLines = Set(new.components(separatedBy: "\n"))
        let added   = newLines.subtracting(oldLines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let removed = oldLines.subtracting(newLines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        return (added, removed)
    }

    private func showSaveToast(file: PersonaFile, diff: (added: Int, removed: Int)) {
        var parts: [String] = [L10n.f("persona.save.toast.saved", fallback: "已保存 %@", file.rawValue)]
        if diff.added > 0 {
            parts.append(L10n.f("persona.save.toast.added", fallback: "+%@ 行", String(diff.added)))
        }
        if diff.removed > 0 {
            parts.append(L10n.f("persona.save.toast.removed", fallback: "−%@ 行", String(diff.removed)))
        }
        saveToast = parts.joined(separator: "  ")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            saveToast = nil
        }
    }

    private func discardEdits(file: PersonaFile) {
        editorContents[file] = savedContents[file] ?? ""
    }

    private func reloadAfterRestore() async {
        if case .file(let file) = selection {
            await loadFile(file)
        }
        showRestoreToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            showRestoreToast = false
        }
    }

    private func deleteCurrentAgent() async {
        guard let agentId = agentId else { return }
        do {
            try await helperClient.removeAgent(username: username, agentId: agentId)
            // 删除后的 UI 刷新由 UserDetailView 的 onChange 处理
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - PersonaFileSidebarView（左侧文件列表）

private struct PersonaFileSidebarView: View {
    @Binding var selection: PersonaSelection
    let editorContents: [PersonaFile: String]
    let savedContents: [PersonaFile: String]
    let existsOnDisk: [PersonaFile: Bool]
    let memoryLogFiles: [String]
    @Binding var memoryLogExpanded: Bool
    let onSelect: (PersonaSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.k("persona.sidebar.title", fallback: "角色文件"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ForEach(PersonaFile.allCases) { file in
                sidebarRow(file)
            }

            // 记忆日志区域
            if !memoryLogFiles.isEmpty {
                Divider().padding(.vertical, 6)

                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { memoryLogExpanded.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: memoryLogExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text(L10n.k("persona.sidebar.memory_logs", fallback: "记忆日志"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(memoryLogFiles.count)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if memoryLogExpanded {
                    ForEach(memoryLogFiles, id: \.self) { name in
                        memoryLogRow(name)
                    }
                }
            }

            Spacer()
        }
        .background(.background)
    }

    @ViewBuilder
    private func sidebarRow(_ file: PersonaFile) -> some View {
        let isSelected = selection == .file(file)
        let isDirty = (editorContents[file] ?? "") != (savedContents[file] ?? "")
        let isNew = !(existsOnDisk[file] ?? true)   // 文件尚未在磁盘创建

        Button(action: { onSelect(.file(file)) }) {
            HStack(spacing: 0) {
                // 图标
                Text(file.icon)
                    .font(.system(size: 13))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(file.rawValue)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isNew ? Color.secondary : Color.primary)

                        if isDirty {
                            Text(L10n.k("persona.sidebar.dirty", fallback: "已改"))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }

                    Text(file.description)
                        .font(.system(size: 10))
                        .foregroundStyle(file == .user ? Color.accentColor.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? Color(NSColor.selectedContentBackgroundColor).opacity(0.15)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if isNew {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 2)
                    .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func memoryLogRow(_ name: String) -> some View {
        let isSelected = selection == .memoryLog(name)
        // 从文件名提取日期显示（去掉 .md 后缀）
        let dateLabel = String(name.dropLast(3))

        Button(action: { onSelect(.memoryLog(name)) }) {
            HStack(spacing: 0) {
                Text("📅")
                    .font(.system(size: 11))
                    .frame(width: 24)
                Text(dateLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected
                    ? Color(NSColor.selectedContentBackgroundColor).opacity(0.15)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PersonaMemoryLogView（记忆日志只读查看）

private struct PersonaMemoryLogView: View {
    let filename: String
    let content: String
    let isLoading: Bool
    let loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(.secondary)
                Text(filename)
                    .font(.headline)
                Spacer()
                Text(L10n.k("persona.memory_log.readonly", fallback: "只读"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if isLoading {
                ProgressView(L10n.k("persona.loading", fallback: "加载中…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(err).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if content.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(L10n.k("persona.memory_log.empty", fallback: "日志为空"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
    }
}

// MARK: - PersonaEditorAreaView（右侧主区域）

private struct PersonaEditorAreaView: View {
    let username: String
    let selectedFile: PersonaFile
    var relPath: String                // 由父视图传入的参数化路径
    @Binding var content: String

    let isLoading: Bool
    let isSaving: Bool
    let isDirty: Bool
    let fileExistsOnDisk: Bool
    let gitInitFailed: Bool
    let lastCommitFailed: Bool
    let loadError: String?
    let historyRefreshToken: Int

    let onSave: () -> Void
    let onDiscard: () -> Void
    let onRestored: () -> Void

    @State private var saveError: String? = nil
    @State private var historyExpanded: Bool = false    // 默认折叠

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            toolbar

            Divider()

            // git init 失败 banner
            if gitInitFailed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L10n.k("persona.git.init_failed",
                                fallback: "历史功能初始化失败，文件仍可编辑"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                Divider()
            }

            // 保存失败提示
            if let err = saveError {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(L10n.f("persona.save.error", fallback: "保存失败：%@", err))
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button { saveError = nil } label: {
                        Image(systemName: "xmark").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.red.opacity(0.06))
                Divider()
            }

            // git commit 失败小字提示
            if lastCommitFailed && !gitInitFailed {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.secondary).font(.caption2)
                    Text(L10n.k("persona.git.commit_failed", fallback: "上次提交失败，历史记录可能不完整"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                Divider()
            }

            if isLoading {
                ProgressView(L10n.k("persona.loading", fallback: "加载中…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                // 离线状态
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(err).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 编辑区（可滚动，占满剩余空间）
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        // 文件不存在时的占位提示
                        if !fileExistsOnDisk && content.isEmpty {
                            HStack {
                                Image(systemName: "doc.badge.plus").foregroundStyle(.secondary)
                                Text(L10n.k("persona.file.not_created",
                                            fallback: "此文件尚未创建，保存后自动生成"))
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.05))
                            Divider()
                        }

                        // 主编辑器
                        TextEditor(text: $content)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 260)
                            .padding(.horizontal, 4)
                    }
                }

                // 修改历史面板（固定在底部，不随编辑器滚动）
                if !gitInitFailed {
                    Divider()
                    PersonaHistoryView(
                        username: username,
                        filename: selectedFile.rawValue,
                        isExpanded: $historyExpanded,
                        refreshToken: historyRefreshToken,
                        onRestored: onRestored
                    )
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(selectedFile.rawValue)
                    .font(.headline)
                Text("~/\(relPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSaving {
                ProgressView().controlSize(.small)
            }

            // 放弃修改
            if isDirty {
                Button(L10n.k("persona.toolbar.discard", fallback: "放弃修改"), action: onDiscard)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isLoading || isSaving)
            }

            // 保存按钮
            Button(L10n.k("persona.toolbar.save", fallback: "保存"), action: onSave)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isLoading || isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - PersonaHistoryView（git 历史面板）

private struct PersonaHistoryView: View {
    let username: String
    let filename: String
    @Binding var isExpanded: Bool
    let refreshToken: Int
    let onRestored: () -> Void

    @Environment(HelperClient.self) private var helperClient

    @State private var commits: [PersonaCommit] = []
    @State private var isLoadingHistory: Bool = false
    @State private var expandedCommit: String? = nil    // 当前展开 diff 的 commit hash
    @State private var diffs: [String: String] = [:]    // hash → diff 字符串缓存
    @State private var loadingDiff: String? = nil
    @State private var revertTarget: PersonaCommit? = nil
    @State private var showRevertAlert: Bool = false
    @State private var revertInProgress: Bool = false
    @State private var revertError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 标题行（可折叠）
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                if isExpanded && commits.isEmpty { Task { await loadHistory() } }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)

                    Text(L10n.k("persona.history.title", fallback: "修改历史"))
                        .font(.caption).fontWeight(.medium)

                    if !commits.isEmpty {
                        Text(L10n.k("persona.history.hint", fallback: "点击提交查看差异 · 可回滚"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isLoadingHistory {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if commits.isEmpty && !isLoadingHistory {
                            Text(L10n.k("persona.history.empty", fallback: "暂无历史记录"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(commits) { commit in
                                commitRow(commit)
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .task {
            if isExpanded { await loadHistory() }
        }
        // 保存成功后外部递增 refreshToken → 自动重载历史
        .onChange(of: refreshToken) { _, _ in
            Task { await loadHistory() }
        }
        // 文件切换时 task 会重跑，这里同步展开状态
        .alert(
            L10n.k("persona.revert.alert.title", fallback: "确认回滚？"),
            isPresented: $showRevertAlert,
            presenting: revertTarget
        ) { commit in
            Button(L10n.k("persona.revert.confirm", fallback: "回滚"), role: .destructive) {
                Task { await doRevert(commit: commit) }
            }
            Button(L10n.k("persona.revert.cancel", fallback: "取消"), role: .cancel) {
                revertTarget = nil
            }
        } message: { commit in
            Text(L10n.f("persona.revert.msg",
                        fallback: "将把 %@ 恢复到「%@」时的内容。",
                        filename, commit.message))
        }
        .alert(
            L10n.k("persona.revert.fail.title", fallback: "回滚失败"),
            isPresented: Binding(get: { revertError != nil }, set: { if !$0 { revertError = nil } })
        ) {
            Button("OK", role: .cancel) { revertError = nil }
        } message: {
            Text(revertError ?? "")
        }
    }

    @ViewBuilder
    private func commitRow(_ commit: PersonaCommit) -> some View {
        let isExpanded = expandedCommit == commit.hash

        VStack(alignment: .leading, spacing: 0) {
            Button(action: { handleCommitTap(commit) }) {
                HStack(spacing: 8) {
                    Text(commit.hash)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(commit.message)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(commit.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // 回滚按钮
                    Button(L10n.k("persona.history.revert", fallback: "回滚")) {
                        revertTarget = commit
                        showRevertAlert = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(revertInProgress)

                    if loadingDiff == commit.hash {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // diff 展开区
            if isExpanded {
                if let diff = diffs[commit.hash] {
                    DiffView(rawDiff: diff)
                }
            }
        }
    }

    // MARK: - 动作

    private func loadHistory() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            commits = try await helperClient.getPersonaFileHistory(username: username, filename: filename)
        } catch {
            commits = []
        }
    }

    private func handleCommitTap(_ commit: PersonaCommit) {
        if expandedCommit == commit.hash {
            expandedCommit = nil
            return
        }
        expandedCommit = commit.hash
        guard diffs[commit.hash] == nil else { return }
        Task { await loadDiff(commit: commit) }
    }

    private func loadDiff(commit: PersonaCommit) async {
        loadingDiff = commit.hash
        defer { loadingDiff = nil }
        do {
            let diff = try await helperClient.getPersonaFileDiff(
                username: username,
                filename: filename,
                commitHash: commit.hash
            )
            diffs[commit.hash] = diff
        } catch {
            diffs[commit.hash] = L10n.f("views.persona_def.diff_load_failed", fallback: "（读取 diff 失败：%@）", error.localizedDescription)
        }
    }

    private func doRevert(commit: PersonaCommit) async {
        revertInProgress = true
        defer { revertInProgress = false }
        do {
            try await helperClient.restorePersonaFileToCommit(
                username: username,
                filename: filename,
                commitHash: commit.hash
            )
            // 回滚成功：清空 diff 缓存，重新加载历史，通知父视图刷新编辑器
            diffs.removeAll()
            expandedCommit = nil
            await loadHistory()
            onRestored()
        } catch {
            revertError = error.localizedDescription
        }
    }
}

// MARK: - DiffView（人类可读的 diff 展示）

/// 解析 unified diff，渲染为带颜色的增删行列表，过滤掉 @@ 行号头。
/// 新增行：绿色背景 + "+"；删除行：红色背景 + "−"；上下文行：灰色。
private struct DiffView: View {

    let rawDiff: String

    // 解析后的行（只保留 +/- 和上下文行，丢弃文件头 diff/index/--- +++ 和 @@ 定位行）
    private var lines: [(kind: LineKind, text: String)] {
        guard !rawDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var result: [(LineKind, String)] = []
        var seenHunk = false        // 遇到第一个 @@ 之后才开始收集

        for raw in rawDiff.components(separatedBy: "\n") {
            // 文件头行（diff --git / index / --- / +++）：跳过
            if raw.hasPrefix("diff ") || raw.hasPrefix("index ") ||
               raw.hasPrefix("--- ") || raw.hasPrefix("+++ ") { continue }

            // @@ 定位行：标记已进入 hunk，本行本身不显示
            if raw.hasPrefix("@@") { seenHunk = true; continue }

            guard seenHunk else { continue }

            if raw.hasPrefix("+") {
                result.append((.added, String(raw.dropFirst())))
            } else if raw.hasPrefix("-") {
                result.append((.removed, String(raw.dropFirst())))
            } else {
                // 上下文行（空行 / 空格开头）
                let text = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
                result.append((.context, text))
            }
        }
        return result
    }

    var body: some View {
        if lines.isEmpty {
            Text(L10n.k("persona.diff.empty", fallback: "（此次提交无内容变化）"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.05))
        } else {
            // 统计摘要
            let addCount    = lines.filter { $0.kind == .added   }.count
            let removeCount = lines.filter { $0.kind == .removed }.count

            VStack(alignment: .leading, spacing: 0) {
                // 摘要行
                HStack(spacing: 10) {
                    if addCount > 0 {
                        Label(L10n.f("persona.diff.added",
                                     fallback: "新增 %@ 行", String(addCount)),
                              systemImage: "plus.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if removeCount > 0 {
                        Label(L10n.f("persona.diff.removed",
                                     fallback: "删除 %@ 行", String(removeCount)),
                              systemImage: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    Spacer()
                }
                .font(.caption2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.07))

                Divider()

                // 逐行渲染
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, pair in
                        diffLine(kind: pair.kind, text: pair.text)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color.secondary.opacity(0.04))
        }
    }

    @ViewBuilder
    private func diffLine(kind: LineKind, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // 符号列
            Text(kind.symbol)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(kind.color.opacity(0.8))
                .frame(width: 10, alignment: .center)

            // 内容
            Text(text.isEmpty ? " " : text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(kind == .context ? Color.primary.opacity(0.6) : kind.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .background(kind.background)
    }

    enum LineKind {
        case added, removed, context

        var symbol: String {
            switch self {
            case .added:   return "+"
            case .removed: return "−"  // Unicode minus，不是连字符
            case .context: return " "
            }
        }

        var color: Color {
            switch self {
            case .added:   return .green
            case .removed: return .red
            case .context: return .primary
            }
        }

        var background: Color {
            switch self {
            case .added:   return Color.green.opacity(0.08)
            case .removed: return Color.red.opacity(0.08)
            case .context: return Color.clear
            }
        }
    }
}
