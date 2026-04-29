// ClawdHome/Views/MemoryTabView.swift
// 记忆 Tab：左侧文件列表 + 顶部搜索 + 右侧内容

import SwiftUI

struct MemoryTabView: View {
    let username: String
    var agentId: String? = nil
    @Environment(HelperClient.self) private var helperClient

    @State private var files: [FileEntry] = []
    @State private var selectedFile: String? = nil
    @State private var fileContent: String = ""
    @State private var loadingContent = false
    @State private var loadingFiles = false

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchResults: [MemoryChunkResult] = []
    @State private var selectedChunk: MemoryChunkResult? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    private var mdFiles: [FileEntry] {
        files.filter { !$0.isDirectory && ($0.name.hasSuffix(".md") || $0.name.hasSuffix(".txt")) }
    }

    var body: some View {
        HSplitView {
            // 左侧：搜索框 + 文件/结果列表
            VStack(spacing: 0) {
                // 搜索框
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField(L10n.k("auto.memory_tab_view.search", fallback: "搜索记忆内容"), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchResults = []
                            selectedChunk = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary).font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quinary)

                Divider()

                if searchText.isEmpty {
                    // 文件列表模式
                    fileListPanel
                } else {
                    // 搜索结果模式
                    searchResultPanel
                }
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

            // 右侧：内容
            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await loadFiles() }
        .onChange(of: selectedFile) { _, path in
            guard let path else { return }
            Task { await loadFileContent(path) }
        }
        .onChange(of: searchText) { _, query in
            searchTask?.cancel()
            guard !query.isEmpty else { return }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await performSearch(query)
            }
        }
    }

    // MARK: - 左侧面板

    @ViewBuilder
    private var fileListPanel: some View {
        if loadingFiles {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mdFiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "brain.head.profile").foregroundStyle(.tertiary).font(.title2)
                Text(L10n.k("auto.memory_tab_view.file", fallback: "暂无记忆文件")).foregroundStyle(.tertiary).font(.subheadline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(mdFiles, selection: $selectedFile) { file in
                MemoryFileRow(file: file)
                    .tag(file.path)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var searchResultPanel: some View {
        if isSearching {
            ProgressView(L10n.k("auto.memory_tab_view.search", fallback: "搜索中…")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchResults.isEmpty {
            Text(L10n.k("auto.memory_tab_view.no_matching_results", fallback: "无匹配结果")).foregroundStyle(.tertiary).font(.subheadline)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(searchResults, selection: Binding(
                get: { selectedChunk?.id },
                set: { id in selectedChunk = searchResults.first(where: { $0.id == id }) }
            )) { chunk in
                SearchResultRow(chunk: chunk, query: searchText)
                    .tag(chunk.id)
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - 右侧面板

    @ViewBuilder
    private var rightPanel: some View {
        if !searchText.isEmpty {
            // 搜索结果详情
            if let chunk = selectedChunk {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(URL(fileURLWithPath: chunk.path).lastPathComponent)
                                .font(.headline)
                            Spacer()
                        }
                        Divider()
                        Text(chunk.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(16)
                }
            } else {
                Text(L10n.k("auto.memory_tab_view.selectsearch", fallback: "选择一条搜索结果")).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            // 文件内容
            if let path = selectedFile {
                VStack(spacing: 0) {
                    // 文件标题栏
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline)
                        Spacer()
                        if let file = mdFiles.first(where: { $0.path == path }) {
                            Text(FormatUtils.formatBytes(file.size))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()

                    if loadingContent {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            Text(fileContent.isEmpty ? L10n.k("auto.memory_tab_view.file", fallback: "（空文件）") : fileContent)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "brain.head.profile").foregroundStyle(.tertiary).font(.largeTitle)
                    Text(L10n.k("auto.memory_tab_view.selectfile", fallback: "选择文件查看记忆内容")).foregroundStyle(.tertiary)
                    Text(L10n.k("auto.memory_tab_view.searchsearch", fallback: "或在上方搜索框搜索关键词")).font(.caption).foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 数据加载

    private func loadFiles() async {
        loadingFiles = true
        defer { loadingFiles = false }
        var groupedEntries: [String: [FileEntry]] = [:]

        for path in MemoryFileLocator.candidateDirectories {
            if let entries = try? await helperClient.listDirectory(
                username: username,
                relativePath: path,
                showHidden: false
            ) {
                groupedEntries[path] = entries
            }
        }

        files = MemoryFileLocator.collectVisibleFiles(groupedEntries: groupedEntries)
    }

    private func loadFileContent(_ relativePath: String) async {
        loadingContent = true
        fileContent = ""
        defer { loadingContent = false }
        guard let data = try? await helperClient.readFile(username: username, relativePath: relativePath),
              let text = String(data: data, encoding: .utf8) else { return }
        fileContent = text
    }

    private func performSearch(_ query: String) async {
        isSearching = true
        defer { isSearching = false }
        guard let results = try? await helperClient.searchMemory(username: username, query: query) else { return }
        searchResults = results
        selectedChunk = results.first
    }
}

// MARK: - 辅助视图

private struct MemoryFileRow: View {
    let file: FileEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.subheadline).lineLimit(1)
                Text(FormatUtils.formatBytes(file.size))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SearchResultRow: View {
    let chunk: MemoryChunkResult
    let query: String

    private var fileName: String {
        URL(fileURLWithPath: chunk.path).lastPathComponent
    }

    private var preview: String {
        let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 80
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(fileName).font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            }
            Text(preview).font(.caption2).foregroundStyle(.primary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
