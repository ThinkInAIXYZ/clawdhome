// ClawdHome/Views/SecurityAuditView.swift
// 安全审计：Gateway 日志、指令记录、配置变更

import SwiftUI
import AppKit

// MARK: - 主视图

struct SecurityAuditView: View {
    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self)   private var pool

    var body: some View {
        TabView {
            GatewayLogTab(users: pool.users.filter { !$0.isAdmin })
                .tabItem { Label(L10n.k("auto.security_audit_view.gateway", fallback: "Gateway 日志"), systemImage: "server.rack") }

            CommandLogTab(users: pool.users.filter { !$0.isAdmin })
                .tabItem { Label(L10n.k("auto.security_audit_view.command_history", fallback: "指令记录"), systemImage: "message") }

            ConfigAuditTab(users: pool.users.filter { !$0.isAdmin })
                .tabItem { Label(L10n.k("auto.security_audit_view.configuration", fallback: "配置变更"), systemImage: "doc.badge.gearshape") }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: - 通用：日志面板（搜索 + 刷新 + 列表）

private struct LogPanel<Entry: Identifiable, Row: View>: View {
    let entries: [Entry]
    let isLoading: Bool
    let searchText: Binding<String>
    let copyText: (() -> String)?
    let onRefresh: () -> Void
    @ViewBuilder let row: (Entry) -> Row

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.k("auto.security_audit_view.search", fallback: "搜索…"), text: searchText).textFieldStyle(.plain)
                Spacer()
                if let copyText {
                    Button {
                        copyToPasteboard(copyText())
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help(L10n.k("auto.security_audit_view.copy_filtered_results", fallback: "复制筛选结果"))
                    .disabled(entries.isEmpty)
                }
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.k("auto.security_audit_view.refresh", fallback: "刷新")).disabled(isLoading)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView(
                    L10n.k("auto.security_audit_view.logs", fallback: "暂无日志"), systemImage: "doc.text",
                    description: Text(L10n.k("auto.security_audit_view.logsfile", fallback: "日志文件为空或尚未产生记录"))
                )
            } else {
                List(entries) { entry in
                    row(entry).listRowSeparator(.visible)
                }
                .listStyle(.plain)
                .font(.system(.caption, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - 通用：带用户选择器的外框

private struct UserPickerFrame<Content: View>: View {
    let users: [ManagedUser]
    @Binding var selectedUser: ManagedUser?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L10n.k("auto.security_audit_view.user", fallback: "用户"), selection: $selectedUser) {
                    Text(L10n.k("auto.security_audit_view.selectuser", fallback: "选择用户…")).tag(Optional<ManagedUser>.none)
                    ForEach(users) { u in
                        Text("🧑 \(u.username)").tag(Optional(u))
                    }
                }
                .labelsHidden().frame(width: 180)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            Divider()

            if selectedUser != nil {
                content()
            } else {
                ContentUnavailableView(L10n.k("auto.security_audit_view.selectuser", fallback: "请选择用户"), systemImage: "person")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 事件级别颜色

private extension Color {
    static func auditLevel(_ level: String) -> Color {
        switch level.uppercased() {
        case "START", "RESTART", "OK":           return .green
        case "STOP", "ERROR", "FAILED", "DENIED": return .red
        case "WARN", "PORT_CONFLICT":             return .orange
        default:                                   return .secondary
        }
    }
}

// MARK: - Gateway 日志 Tab

private struct GatewayLogTab: View {
    let users: [ManagedUser]
    @Environment(HelperClient.self) private var helperClient
    @State private var selectedUser: ManagedUser?
    @State private var entries: [GatewayLogEntry] = []
    @State private var isLoading = false
    @State private var searchText = ""

    private var filtered: [GatewayLogEntry] {
        entries.filter { LogSearchMatcher.matches(text: $0.raw, query: searchText) }
    }

    var body: some View {
        UserPickerFrame(users: users, selectedUser: $selectedUser) {
            LogPanel(entries: filtered, isLoading: isLoading,
                     searchText: $searchText,
                     copyText: { filtered.map(\.raw).joined(separator: "\n") },
                     onRefresh: { Task { await load() } }) { entry in
                GatewayLogRow(entry: entry)
            }
        }
        .onChange(of: selectedUser) { _, _ in Task { await load() } }
        .task { if selectedUser == nil { selectedUser = users.first } }
    }

    private func load() async {
        guard let user = selectedUser else { return }
        isLoading = true
        defer { isLoading = false }
        let relativePath = user.prefersHermesRuntime
            ? ".hermes/logs/gateway.log"
            : ".openclaw/logs/gateway.log"
        let data = (try? await helperClient.readFile(
            username: user.username,
            relativePath: relativePath
        )) ?? Data()
        entries = GatewayLogEntry.parse(data: data)
    }
}

private struct GatewayLogRow: View {
    let entry: GatewayLogEntry
    var body: some View {
        Text(entry.raw)
            .foregroundStyle(.primary)
            .padding(.vertical, 2)
    }
}

// MARK: - 指令记录 Tab

private struct CommandLogTab: View {
    let users: [ManagedUser]
    @Environment(HelperClient.self) private var helperClient
    @State private var selectedUser: ManagedUser?
    @State private var entries: [CommandLogEntry] = []
    @State private var isLoading = false
    @State private var searchText = ""

    private var filtered: [CommandLogEntry] {
        entries.filter { LogSearchMatcher.matches(text: $0.raw, query: searchText) }
    }

    var body: some View {
        UserPickerFrame(users: users, selectedUser: $selectedUser) {
            LogPanel(entries: filtered, isLoading: isLoading,
                     searchText: $searchText,
                     copyText: { filtered.map(\.raw).joined(separator: "\n") },
                     onRefresh: { Task { await load() } }) { entry in
                CommandLogRow(entry: entry)
            }
        }
        .onChange(of: selectedUser) { _, _ in Task { await load() } }
        .task { if selectedUser == nil { selectedUser = users.first } }
    }

    private func load() async {
        guard let user = selectedUser else { return }
        isLoading = true
        defer { isLoading = false }
        let data = (try? await helperClient.readFile(
            username: user.username,
            relativePath: ".openclaw/logs/commands.log"
        )) ?? Data()
        entries = CommandLogEntry.parse(data: data)
    }
}

private struct CommandLogRow: View {
    let entry: CommandLogEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(entry.action)
                    .fontWeight(.semibold).foregroundStyle(Color.accentColor)
                    .frame(width: 64, alignment: .leading)
                Text("[\(entry.timestamp)]").foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Label(entry.senderId, systemImage: "person")
                Text("via \(entry.source)")
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 72)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 配置变更 Tab

private struct ConfigAuditTab: View {
    let users: [ManagedUser]
    @Environment(HelperClient.self) private var helperClient
    @State private var selectedUser: ManagedUser?
    @State private var entries: [ConfigAuditEntry] = []
    @State private var isLoading = false
    @State private var searchText = ""

    private var filtered: [ConfigAuditEntry] {
        entries.filter { LogSearchMatcher.matches(text: $0.raw, query: searchText) }
    }

    var body: some View {
        UserPickerFrame(users: users, selectedUser: $selectedUser) {
            LogPanel(entries: filtered, isLoading: isLoading,
                     searchText: $searchText,
                     copyText: { filtered.map(\.raw).joined(separator: "\n") },
                     onRefresh: { Task { await load() } }) { entry in
                ConfigAuditRow(entry: entry)
            }
        }
        .onChange(of: selectedUser) { _, _ in Task { await load() } }
        .task { if selectedUser == nil { selectedUser = users.first } }
    }

    private func load() async {
        guard let user = selectedUser else { return }
        isLoading = true
        defer { isLoading = false }
        let data = (try? await helperClient.readFile(
            username: user.username,
            relativePath: ".openclaw/logs/config-audit.jsonl"
        )) ?? Data()
        entries = ConfigAuditEntry.parse(data: data)
    }
}

private struct ConfigAuditRow: View {
    let entry: ConfigAuditEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(entry.result)
                    .fontWeight(.semibold)
                    .foregroundStyle(entry.result == "ok" ? Color.green : Color.orange)
                    .frame(width: 56, alignment: .leading)
                Text("[\(entry.ts)]").foregroundStyle(.secondary)
                if let changed = entry.changedPathCount {
                    Text("\(changed) paths changed").foregroundStyle(.secondary)
                }
                if let bytes = entry.nextBytes {
                    Text("→ \(bytes) bytes").foregroundStyle(.secondary)
                }
            }
            if let path = entry.configPath {
                Text(path).foregroundStyle(.secondary).padding(.leading, 64)
            }
            if !entry.suspicious.isEmpty {
                Text("⚠ \(entry.suspicious.joined(separator: ", "))")
                    .foregroundStyle(.orange).padding(.leading, 64)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 数据模型与解析

struct GatewayLogEntry: Identifiable {
    let id = UUID()
    let raw: String

    // 原始 stdout/stderr 行，直接展示
    static func parse(data: Data) -> [GatewayLogEntry] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .reversed()
            .map { GatewayLogEntry(raw: LogTimestampFormatter.normalizeLinePrefix($0)) }
    }
}

struct CommandLogEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let action: String
    let sessionKey: String
    let senderId: String
    let source: String
    let raw: String

    static func parse(data: Data) -> [CommandLogEntry] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .reversed()
            .compactMap { line -> CommandLogEntry? in
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String]
                else { return nil }
                let normalizedTs = LogTimestampFormatter.normalizeTimestamp(obj["timestamp"] ?? "")
                return CommandLogEntry(
                    timestamp:  normalizedTs,
                    action:     obj["action"]     ?? "",
                    sessionKey: obj["sessionKey"] ?? "",
                    senderId:   obj["senderId"]   ?? "unknown",
                    source:     obj["source"]     ?? "unknown",
                    raw: line
                )
            }
    }
}

struct ConfigAuditEntry: Identifiable {
    let id = UUID()
    let ts: String             // "ts" 字段（ISO8601）
    let result: String         // "ok" | "failed" | "rename" 等
    let configPath: String?
    let nextBytes: Int?
    let changedPathCount: Int?
    let suspicious: [String]   // "suspicious" 字段（数组）
    let raw: String

    static func parse(data: Data) -> [ConfigAuditEntry] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .reversed()
            .compactMap { line -> ConfigAuditEntry? in
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { return nil }
                let suspicious = (obj["suspicious"] as? [String]) ?? []
                let normalizedTs = LogTimestampFormatter.normalizeTimestamp(
                    obj["ts"] as? String ?? ""
                )
                return ConfigAuditEntry(
                    ts:               normalizedTs,
                    result:           obj["result"]          as? String ?? "",
                    configPath:       obj["configPath"]      as? String,
                    nextBytes:        obj["nextBytes"]       as? Int,
                    changedPathCount: obj["changedPathCount"] as? Int,
                    suspicious:       suspicious,
                    raw: line
                )
            }
    }
}
