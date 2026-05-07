// ClawdHome/Views/LogViewerSheet.swift
// 展示指定用户的 openclaw-gateway 日志
// GatewayLogViewer 是可嵌入 Tab 的核心组件；LogViewerSheet 是浮窗壳

import SwiftUI
import AppKit

// MARK: - 核心日志查看器（可嵌入 Tab 或 Sheet）

struct GatewayLogViewer: View {
    let username: String
    var externalSearchQuery: Binding<String>? = nil

    @Environment(HelperClient.self) private var helperClient
    @State private var lines: [String]  = []
    @State private var searchQuery      = ""
    @State private var isPaused         = false
    @State private var isFollowing      = true
    @State private var lineCount        = 200
    @State private var lastDataSize: Int = -1   // 大小未变则跳过解析

    private let lineOptions = [50, 100, 200, 500]
    private var activeSearchQuery: String {
        if let externalSearchQuery {
            return externalSearchQuery.wrappedValue
        }
        return searchQuery
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { activeSearchQuery },
            set: { newValue in
                if let externalSearchQuery {
                    externalSearchQuery.wrappedValue = newValue
                } else {
                    searchQuery = newValue
                }
            }
        )
    }

    private var filteredLines: [String] {
        lines.filter { LogSearchMatcher.matches(text: $0, query: activeSearchQuery) }
    }
    private var filteredLogText: String {
        filteredLines.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbarRow
            Divider()
            if isPaused {
                pauseBanner
                Divider()
            }
            logBody
        }
        .task { await pollLoop() }
    }

    // MARK: - 工具栏

    private var toolbarRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Picker("", selection: $lineCount) {
                    ForEach(lineOptions, id: \.self) { n in
                        Text(L10n.f("views.log_viewer_sheet.text_825ac330", fallback: "最近 %@ 行", String(describing: n))).tag(n)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 100)
                .onChange(of: lineCount) { _, _ in
                    lastDataSize = -1   // 强制下次重解析
                    if !isPaused { Task { await loadLog() } }
                }

                Divider().frame(height: 16)

                Button {
                    isPaused.toggle()
                    if !isPaused { Task { await loadLog() } }
                } label: {
                    Label(isPaused ? L10n.k("auto.log_viewer_sheet.continue", fallback: "继续") : L10n.k("auto.log_viewer_sheet.pause", fallback: "暂停"),
                          systemImage: isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 60)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Toggle(L10n.k("auto.log_viewer_sheet.follow", fallback: "跟随"), isOn: $isFollowing)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(isPaused)
                TextField(L10n.k("auto.log_viewer_sheet.search_space_separated_terms", fallback: "搜索（空格分词）"), text: searchQueryBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button(L10n.k("auto.log_viewer_sheet.copy_filtered", fallback: "复制筛选")) { copyFilteredLogs() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 34)
    }

    private var pauseBanner: some View {
        HStack {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            Text(L10n.k("auto.log_viewer_sheet.refresh_select", fallback: "刷新已暂停，内容已固定，可自由选择复制"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - 日志体（单文本，支持稳定跨行选择）

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(filteredLines.isEmpty ? L10n.k("auto.log_viewer_sheet.logs", fallback: "（日志为空）") : filteredLogText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(filteredLines.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 1)
                    Color.clear.frame(height: 0).id("bottom")
                }
                .textSelection(.enabled)
            }
            .onChange(of: filteredLines.count) { _, _ in
                if isFollowing && !isPaused {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - 轮询（1 秒间隔）

    private func pollLoop() async {
        await loadLog()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { break }
            if !isPaused { await loadLog() }
        }
    }

    private func loadLog() async {
        let data: Data
        do {
            // 日志文件可能远超 10MB，只读取尾部窗口以保证可查看性与性能
            data = try await helperClient.readFileTail(
                username: username,
                relativePath: ".openclaw/logs/gateway.log",
                maxBytes: max(lineCount * 512, 128 * 1024)
            )
        } catch {
            lines = [
                L10n.k("auto.log_viewer_sheet.logs", fallback: "读取日志失败："),
                error.localizedDescription,
                "",
                L10n.k("auto.log_viewer_sheet.logs", fallback: "日志路径："),
                "/Users/\(username)/.openclaw/logs/gateway.log"
            ]
            lastDataSize = -1
            return
        }

        // 文件大小未变且已有内容 → 跳过重解析
        guard data.count != lastDataSize || lines.isEmpty else { return }
        lastDataSize = data.count

        if data.isEmpty {
            lines = [
                L10n.k("auto.log_viewer_sheet.logsfile", fallback: "日志文件为空或不存在："),
                "/Users/\(username)/.openclaw/logs/gateway.log",
                "",
                L10n.k("auto.log_viewer_sheet.gateway_startlogs", fallback: "gateway 启动后才会生成日志。")
            ]
            return
        }

        var parsed = (String(data: data, encoding: .utf8) ?? "")
            .components(separatedBy: "\n")
        // readFileTail 可能从中间字节切入，首行可能是半行
        if parsed.count > 1 {
            parsed.removeFirst()
        }
        lines = Array(parsed.suffix(lineCount))
            .map { Self.cleanLogLine($0) }
            .map(LogTimestampFormatter.normalizeLinePrefix)
    }

    private func copyFilteredLogs() {
        let text = filteredLines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 兼容两类彩色控制码：
    /// 1) 标准 ANSI（含 ESC 前缀）
    /// 2) 历史日志里残留的文本片段（如 "[35m"）
    private static func cleanLogLine(_ line: String) -> String {
        let withoutAnsi = line.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        return withoutAnsi.replacingOccurrences(
            of: #"\[[0-9;]*m"#,
            with: "",
            options: .regularExpression
        )
    }
}

// MARK: - 浮窗壳（从 DashboardView / UserListView 弹出）

struct LogViewerSheet: View {
    let username: String

    @Environment(\.dismiss) private var dismiss

    private var logPath: String {
        "/Users/\(username)/.openclaw/logs/gateway.log"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.f("views.log_viewer_sheet.text_d8b7f1fb", fallback: "日志 — @%@", String(describing: username))).font(.headline)
                    Text(logPath).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.k("auto.log_viewer_sheet.close", fallback: "关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
            Divider()
            GatewayLogViewer(username: username)
        }
        .frame(width: 700, height: 480)
    }
}
