// ClawdHome/Views/SessionsTabView.swift
// 会话 Tab：左侧列表 + 右侧完整转录

import SwiftUI

// MARK: - 数据模型

struct SessionEntry: Identifiable {
    var id: String { key }
    let key: String
    let updatedAt: Double       // ms 时间戳
    let inputTokens: Int?
    let outputTokens: Int?
    let model: String?
    let modelProvider: String?
    let label: String?
    let sessionFile: String?    // JSONL 路径（可能是相对或绝对）
    let sessionId: String?      // Gateway sessions.list 提供的会话 ID
    let chatType: String?

    /// 从 RPC 返回的字典解析
    static func from(_ d: [String: Any]) -> SessionEntry? {
        guard let key = d["key"] as? String else { return nil }
        let updatedAt = (d["updatedAt"] as? Double) ?? 0
        return SessionEntry(
            key: key,
            updatedAt: updatedAt,
            inputTokens:   d["inputTokens"]   as? Int,
            outputTokens:  d["outputTokens"]  as? Int,
            model:         d["model"]         as? String,
            modelProvider: d["modelProvider"] as? String,
            label:         d["label"]         as? String,
            sessionFile:   d["sessionFile"]   as? String,
            sessionId:     d["sessionId"]     as? String,
            chatType:      d["chatType"]       as? String
        )
    }

    var displayName: String {
        if let label, !label.isEmpty { return label }
        // 从 key 解析来源：agent:main:direct:telegram → "Telegram"
        let parts = key.split(separator: ":").map(String.init)
        if parts.count >= 3 {
            let platform = parts[2]
            switch platform {
            case "direct":   return parts.count > 3 ? "\(L10n.k("views.sessions_tab_view.direct_message", fallback: "私聊")) · \(parts[3])" : L10n.k("views.sessions_tab_view.direct_message", fallback: "私聊")
            case "group":    return parts.count > 3 ? "\(L10n.k("views.sessions_tab_view.group", fallback: "群组")) · \(parts[3])" : L10n.k("views.sessions_tab_view.group", fallback: "群组")
            case "cron":     return L10n.k("views.sessions_tab_view.scheduled_tasks", fallback: "定时任务")
            case "channel":  return parts.count > 3 ? "\(L10n.k("views.sessions_tab_view.channel", fallback: "频道")) · \(parts[3])" : L10n.k("views.sessions_tab_view.channel", fallback: "频道")
            default:         return platform
            }
        }
        return key
    }

    var platformIcon: String {
        let parts = key.split(separator: ":").map(String.init)
        let platform = parts.count >= 3 ? parts[2] : ""
        switch platform {
        case "direct":  return "message"
        case "group":   return "person.3"
        case "cron":    return "clock"
        case "channel": return "megaphone"
        default:        return "bubble.left.and.bubble.right"
        }
    }

    var totalTokens: Int { (inputTokens ?? 0) + (outputTokens ?? 0) }

    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}

// MARK: - 转录消息

struct TranscriptMessage: Identifiable {
    let id: UUID = UUID()
    let role: String        // user / assistant / system / tool
    let content: String
    let timestamp: Double?  // ms
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
}

// MARK: - 主视图

struct SessionsTabView: View {
    let username: String
    var agentId: String? = nil
    @Environment(GatewayHub.self) private var hub
    @Environment(HelperClient.self) private var helperClient

    @State private var sessions: [SessionEntry] = []
    @State private var selectedKey: String? = nil
    @State private var transcript: [TranscriptMessage] = []
    @State private var loadingTranscript = false
    @State private var transcriptError: String? = nil
    @State private var loadingSessions = false
    @State private var searchText = ""

    private var filteredSessions: [SessionEntry] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.key.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HSplitView {
            // 左侧：会话列表
            VStack(spacing: 0) {
                // 搜索框
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField(L10n.k("views.sessions_tab_view.searchsession", fallback: "搜索会话"), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quinary)

                Divider()

                if loadingSessions {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredSessions.isEmpty {
                    Text(sessions.isEmpty ? L10n.k("views.sessions_tab_view.session", fallback: "暂无会话") : L10n.k("views.sessions_tab_view.no_matching_results", fallback: "无匹配结果"))
                        .foregroundStyle(.tertiary)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredSessions, selection: $selectedKey) { session in
                        SessionRowView(session: session)
                            .tag(session.key)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)

            // 右侧：转录内容
            transcriptPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await loadSessions() }
        .onChange(of: selectedKey) { _, key in
            guard let key else { return }
            Task { await loadTranscript(for: key) }
        }
    }

    // MARK: - 右侧面板

    @ViewBuilder
    private var transcriptPanel: some View {
        if let key = selectedKey {
            VStack(spacing: 0) {
                // 标题栏
                if let session = sessions.first(where: { $0.key == key }) {
                    HStack(spacing: 8) {
                        Image(systemName: session.platformIcon).foregroundStyle(.secondary)
                        Text(session.displayName).font(.headline)
                        Spacer()
                        if session.totalTokens > 0 {
                            Text(formatTokens(session.totalTokens))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let model = session.model {
                            Text(model).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(session.updatedDate, style: .relative)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()
                }

                if loadingTranscript {
                    ProgressView(L10n.k("views.sessions_tab_view.loading", fallback: "加载中…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = transcriptError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(err).foregroundStyle(.secondary).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if transcript.isEmpty {
                    Text(L10n.k("views.sessions_tab_view.empty_session", fallback: "会话为空")).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(transcript) { msg in
                                    TranscriptBubble(message: msg)
                                        .id(msg.id)
                                }
                            }
                            .padding(16)
                        }
                        .onAppear {
                            if let last = transcript.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        } else {
            Text(L10n.k("views.sessions_tab_view.selectsession", fallback: "选择一个会话查看完整对话"))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 数据加载

    private func loadSessions() async {
        loadingSessions = true
        defer { loadingSessions = false }
        do {
            let result = try await hub.request(
                username: username,
                method: "sessions.list",
                params: ["limit": 100, "includeDerivedTitles": true, "includeLastMessage": false]
            )
            guard let payload = result,
                  let items = payload["sessions"] as? [[String: Any]] else { return }
            sessions = items.compactMap { SessionEntry.from($0) }
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            // gateway 未连接时静默失败
        }
    }

    private func loadTranscript(for key: String) async {
        guard let session = sessions.first(where: { $0.key == key }) else { return }
        loadingTranscript = true
        transcriptError = nil
        transcript = []
        defer { loadingTranscript = false }

        let paths = resolveSessionTranscriptRelativePaths(
            sessionFile: session.sessionFile,
            sessionId: session.sessionId,
            key: key
        )

        var rawData: Data? = nil
        for path in paths {
            if let data = try? await helperClient.readFile(username: username, relativePath: path) {
                rawData = data
                break
            }
        }
        guard let data = rawData,
              let text = String(data: data, encoding: .utf8) else {
            transcriptError = L10n.k("views.sessions_tab_view.sessionfile", fallback: "找不到会话文件")
            return
        }
        transcript = parseJSONL(text)
    }

    // MARK: - JSONL 解析

    private func parseJSONL(_ text: String) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // 跳过 header/compaction 记录
            if let type_ = obj["type"] as? String, type_ != "message" {
                // type == "sessionL10n.k("views.sessions_tab_view.header", fallback: " 是 header，")compaction" 是压缩标记
                if type_ != "message" { continue }
            }

            guard let msg = obj["message"] as? [String: Any],
                  let role = msg["role"] as? String
            else { continue }

            let content = extractContent(msg["content"])
            guard !content.isEmpty else { continue }

            let usage = msg["usage"] as? [String: Any]
            messages.append(TranscriptMessage(
                role: role,
                content: content,
                timestamp: msg["timestamp"] as? Double,
                model: msg["model"] as? String,
                inputTokens:  usage?["input"]  as? Int,
                outputTokens: usage?["output"] as? Int
            ))
        }
        return messages
    }

    private func extractContent(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let arr = raw as? [[String: Any]] {
            return arr.compactMap { block -> String? in
                guard let type_ = block["type"] as? String else { return nil }
                switch type_ {
                case "text":         return block["text"] as? String
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    return String(format: L10n.k("views.sessions_tab_view.tool_call_block", fallback: "[工具调用: %@]"), name)
                case "tool_result":  return L10n.k("views.sessions_tab_view.tool_result_block", fallback: "[工具结果]")
                default:             return nil
                }
            }.joined(separator: "\n")
        }
        return ""
    }

    private func formatTokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk tok", Double(n) / 1000) : "\(n) tok"
    }
}

// MARK: - 会话行

private struct SessionRowView: View {
    let session: SessionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: session.platformIcon)
                    .font(.caption2).foregroundStyle(.secondary)
                Text(session.displayName)
                    .font(.subheadline).fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text(session.updatedDate, style: .relative)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if let model = session.model {
                    Text(model).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                if session.totalTokens > 0 {
                    Text("\(formatTokens(session.totalTokens))")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func formatTokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

// MARK: - 对话气泡

private struct TranscriptBubble: View {
    let message: TranscriptMessage

    private var isUser: Bool { message.role == "user" }
    private var isSystem: Bool { message.role == "system" }
    private var isTool: Bool { message.role == "tool" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                // 角色标签
                HStack(spacing: 4) {
                    if !isUser {
                        Image(systemName: roleIcon)
                            .font(.caption2)
                            .foregroundStyle(roleColor)
                        Text(roleLabel)
                            .font(.caption2).foregroundStyle(.secondary)
                        if let model = message.model {
                            Text("· \(model)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    } else {
                        Text(roleLabel).font(.caption2).foregroundStyle(.secondary)
                        Image(systemName: roleIcon)
                            .font(.caption2).foregroundStyle(roleColor)
                    }
                }

                // 内容气泡
                Text(message.content)
                    .font(.system(.callout))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(isUser ? .white : .primary)

                // 底部 token 信息
                if let tin = message.inputTokens, let tout = message.outputTokens {
                    Text("↑\(tin) ↓\(tout)")
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case "user":      return L10n.k("views.sessions_tab_view.user", fallback: "用户")
        case "assistant": return L10n.k("views.sessions_tab_view.assistant", fallback: "助手")
        case "system":    return L10n.k("views.sessions_tab_view.system", fallback: "系统")
        case "tool":      return L10n.k("views.sessions_tab_view.tools", fallback: "工具")
        default:          return message.role
        }
    }

    private var roleIcon: String {
        switch message.role {
        case "user":      return "person.circle"
        case "assistant": return "cpu"
        case "system":    return "gearshape"
        case "tool":      return "wrench.and.screwdriver"
        default:          return "bubble.left"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case "user":      return .blue
        case "assistant": return .green
        case "system":    return .orange
        case "tool":      return .purple
        default:          return .secondary
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case "user":      return .blue
        case "assistant": return Color(.controlBackgroundColor)
        case "system":    return .orange.opacity(0.15)
        case "tool":      return .purple.opacity(0.12)
        default:          return .secondary.opacity(0.12)
        }
    }
}
