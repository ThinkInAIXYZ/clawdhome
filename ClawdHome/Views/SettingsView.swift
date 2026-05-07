// ClawdHome/Views/SettingsView.swift

import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(HelperClient.self) private var helperClient
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(0)

            AppLogTab()
                .tabItem { Label("App 日志", systemImage: "app.badge") }
                .tag(1)

            HelperLogTab()
                .tabItem { Label("Helper 日志", systemImage: "terminal") }
                .tag(2)

            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(3)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 400)
    }
}

// MARK: - 通用设置

private struct GeneralSettingsTab: View {
    @Environment(HelperClient.self) private var helperClient
    @State private var gatewayAutostart = true
    @AppStorage("clawPoolShowCurrentAdmin") private var showCurrentAdminInPool = false

    var body: some View {
        Form {
            Section("Gateway") {
                Toggle("开机自动启动所有虾的 Gateway", isOn: $gatewayAutostart)
                    .onChange(of: gatewayAutostart) { _, newValue in
                        Task { try? await helperClient.setGatewayAutostart(enabled: newValue) }
                    }
                Text("Mac 开机后，Helper 会自动为所有已初始化的虾启动 Gateway，无需登录管理员账户。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("虾塘显示") {
                Toggle("显示当前管理员账户（不推荐）", isOn: $showCurrentAdminInPool)
                if showCurrentAdminInPool {
                    Label("风险提示：管理员账户权限高，误操作会影响系统级配置。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("安全保障：ClawdHome 已对管理员账户禁用部分高风险动作（如重置/删除），但仍建议日常只使用标准用户账户。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("默认隐藏管理员账户，仅展示标准用户。需要排障时可临时开启。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            AppLockSection()

            Section("关于") {
                LabeledContent("版本", value: "ClawdHome 1.0")
                LabeledContent("Helper", value: "/Library/PrivilegedHelperTools/io.github.deepjerry.clawdhome.mac.helper")
            }
        }
        .formStyle(.grouped)
        .task {
            if helperClient.isConnected {
                gatewayAutostart = await helperClient.getGatewayAutostart()
            }
        }
    }
}

// MARK: - App 锁定设置区

private struct AppLockSection: View {
    @Environment(AppLockStore.self) private var lockStore
    @State private var showSetPassword = false
    @State private var showDisableLock = false
    @State private var showChangePassword = false

    var body: some View {
        Section("隐私与安全") {
            if lockStore.isEnabled {
                LabeledContent("App 锁定") {
                    HStack(spacing: 8) {
                        Text("已启用").foregroundStyle(.secondary)
                        Button("更改密码") { showChangePassword = true }
                            .buttonStyle(.borderless)
                        Button("关闭锁定") { showDisableLock = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                    }
                }

                if lockStore.isBiometricAvailable {
                    Toggle("使用 Touch ID 解锁", isOn: Binding(
                        get: { lockStore.isBiometricEnabled },
                        set: { lockStore.setBiometricEnabled($0) }
                    ))
                }

                Text("启用锁定后，每次开机或系统屏幕锁定后需输入管理密码才能使用 ClawdHome。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("App 锁定") {
                    Button("设置密码…") { showSetPassword = true }
                        .buttonStyle(.borderless)
                }
                Text("设置管理密码后，App 启动及系统锁屏后将需要验证身份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showSetPassword) {
            SetPasswordSheet(mode: .set)
        }
        .sheet(isPresented: $showChangePassword) {
            SetPasswordSheet(mode: .change)
        }
        .sheet(isPresented: $showDisableLock) {
            DisableLockSheet()
        }
    }
}

// MARK: - 设置/更改密码 Sheet

private struct SetPasswordSheet: View {
    enum Mode { case set, change }
    let mode: Mode

    @Environment(AppLockStore.self) private var lockStore
    @Environment(\.dismiss) private var dismiss

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(mode == .set ? "设置管理密码" : "更改管理密码")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                if mode == .change {
                    SecureField("当前密码", text: $oldPassword)
                        .textFieldStyle(.roundedBorder)
                }
                SecureField("新密码（至少 6 位）", text: $newPassword)
                    .textFieldStyle(.roundedBorder)
                SecureField("确认新密码", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
            }

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button(mode == .set ? "启用锁定" : "确认更改") { commit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newPassword.count < 6 || newPassword != confirmPassword)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func commit() {
        guard newPassword == confirmPassword else {
            error = "两次输入的密码不一致"; return
        }
        guard newPassword.count >= 6 else {
            error = "密码至少需要 6 位"; return
        }
        if mode == .change {
            switch lockStore.changePassword(old: oldPassword, new: newPassword) {
            case .success: break
            case .wrongPassword:  error = "当前密码错误"; return
            case .keychainDenied: error = "Keychain 访问被拒绝，请在系统弹窗中允许"; return
            }
        } else {
            lockStore.setPassword(newPassword)
        }
        dismiss()
    }
}

// MARK: - 关闭锁定 Sheet

private struct DisableLockSheet: View {
    @Environment(AppLockStore.self) private var lockStore
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("关闭 App 锁定").font(.headline)
            Text("请输入当前管理密码以确认关闭。")
                .font(.subheadline).foregroundStyle(.secondary)

            SecureField("当前密码", text: $password)
                .textFieldStyle(.roundedBorder)

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("关闭锁定") {
                    switch lockStore.disableLock(password: password) {
                    case .success:        dismiss()
                    case .wrongPassword:  error = "密码错误"
                    case .keychainDenied: error = "Keychain 访问被拒绝，请在系统弹窗中允许"
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

// MARK: - App 日志查看器

private struct AppLogTab: View {
    @State private var appLogger = AppLogger.shared
    @State private var isFollowing = true
    @State private var levelFilter = "全部"
    @State private var searchQuery = ""

    private let filterOptions = ["全部", "INFO", "WARN", "ERROR"]

    private var filteredLines: [AppLogger.LogLine] {
        var lines = appLogger.lines
        if levelFilter != "全部" {
            lines = lines.filter { $0.level.rawValue == levelFilter }
        }
        lines = lines.filter { LogSearchMatcher.matches(text: $0.formatted, query: searchQuery) }
        return lines
    }
    private var filteredLogText: String {
        filteredLines.map(\.formatted).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Text("App 内存日志（最近 500 条）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(selection: $levelFilter) {
                        ForEach(filterOptions, id: \.self) { Text($0) }
                    } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    Toggle("自动滚动", isOn: $isFollowing)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    TextField("搜索（空格分词）", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Button("复制筛选") { copyFilteredLogs() }
                        .controlSize(.small)
                    Button("清空") { appLogger.clear() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 34)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(filteredLines.isEmpty ? "（暂无日志）" : filteredLogText)
                            .foregroundStyle(filteredLines.isEmpty ? .tertiary : .primary)
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                    .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: filteredLines.count) { _, _ in
                    if isFollowing {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func copyFilteredLogs() {
        let text = filteredLines.map(\.formatted).joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Helper 日志查看器

struct HelperLogTab: View {
    @Environment(HelperClient.self) private var helperClient
    @State private var logLines: [ParsedLogLine] = []
    @State private var isFollowing = true
    @State private var timer: Timer?
    @State private var levelFilter = "全部"
    @State private var selectedChannel: LogChannel = .all
    @State private var debugLoggingEnabled = false
    @State private var suppressDebugToggleCallback = false
    @State private var searchQuery = ""
    @State private var isPaused = false
    @State private var fileOffset: UInt64 = 0
    @State private var pendingFragment = ""
    @State private var nextLineID: Int = 0
    @State private var isReading = false

    private struct JSONLogLine: Codable {
        let ts: String
        let level: String
        let channel: String
        let message: String
        let pid: Int32?
    }

    private struct ParsedLogLine: Identifiable {
        let id: String
        let text: String
        let level: String?
        let channel: String?
    }

    private enum LogChannel: String, CaseIterable, Identifiable {
        case all = "全部"
        case primary = "主日志"
        case fileIO = "文件IO"
        case diagnostics = "诊断"
        var id: String { rawValue }
        var channelKey: String? {
            switch self {
            case .all: return nil
            case .primary: return "PRIMARY"
            case .fileIO: return "FILEIO"
            case .diagnostics: return "DIAG"
            }
        }
    }

    private let logPath = "/tmp/clawdhome-helper.log"
    private let maxRenderedLines = 400
    private let filterOptions = ["全部", "DEBUG", "INFO", "WARN", "ERROR"]

    private var filteredLines: [ParsedLogLine] {
        var lines = logLines
        if levelFilter != "全部" {
            lines = lines.filter { $0.level == levelFilter }
        }
        if let key = selectedChannel.channelKey {
            lines = lines.filter { $0.channel == key }
        }
        lines = lines.filter { LogSearchMatcher.matches(text: $0.text, query: searchQuery) }
        return lines
    }
    private var filteredLogText: String {
        filteredLines.map(\.text).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Text(logPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(selection: $selectedChannel) {
                        ForEach(LogChannel.allCases) { channel in
                            Text(channel.rawValue).tag(channel)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    Picker(selection: $levelFilter) {
                        ForEach(filterOptions, id: \.self) { Text($0) }
                    } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    Toggle("DEBUG 日志", isOn: $debugLoggingEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: debugLoggingEnabled) { oldValue, newValue in
                            if suppressDebugToggleCallback {
                                suppressDebugToggleCallback = false
                                return
                            }
                            Task {
                                do {
                                    try await helperClient.setHelperDebugLogging(enabled: newValue)
                                } catch {
                                    suppressDebugToggleCallback = true
                                    debugLoggingEnabled = oldValue
                                }
                            }
                        }
                    Toggle("自动滚动", isOn: $isFollowing)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Toggle("暂停刷新", isOn: $isPaused)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    TextField("搜索（空格分词）", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Button("复制筛选") { copyFilteredLogs() }
                        .controlSize(.small)
                    Button("清空") {
                        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
                        for idx in 1...3 {
                            try? FileManager.default.removeItem(atPath: "\(logPath).\(idx)")
                        }
                        logLines = []
                        fileOffset = 0
                        pendingFragment = ""
                        nextLineID = 0
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 34)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(filteredLines.isEmpty ? "（日志为空）" : filteredLogText)
                            .foregroundStyle(filteredLines.isEmpty ? .tertiary : .primary)
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                    .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: filteredLines.count) { _, _ in
                    if isFollowing {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .onAppear {
            loadLog(reset: true)
            startTimer()
            Task { debugLoggingEnabled = await helperClient.getHelperDebugLogging() }
        }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func loadLog(reset: Bool = false) {
        guard !isReading else { return }
        isReading = true

        let startOffset = reset ? 0 : fileOffset
        let startFragment = reset ? "" : pendingFragment
        let startLines = reset ? [] : logLines
        let startID = reset ? 0 : nextLineID

        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: logPath),
                  let sizeNum = attrs[.size] as? NSNumber else {
                DispatchQueue.main.async {
                    logLines = []
                    fileOffset = 0
                    pendingFragment = ""
                    nextLineID = 0
                    isReading = false
                }
                return
            }

            let fileSize = UInt64(sizeNum.int64Value)
            var offset = startOffset
            var fragment = startFragment
            var lines = startLines
            var runningID = startID

            // 文件被轮转或截断
            if fileSize < offset {
                offset = 0
                fragment = ""
                lines = []
                runningID = 0
            }

            guard let fh = FileHandle(forReadingAtPath: logPath) else {
                DispatchQueue.main.async {
                    isReading = false
                }
                return
            }
            defer { try? fh.close() }

            try? fh.seek(toOffset: offset)
            let data = fh.readDataToEndOfFile()
            let newOffset = offset + UInt64(data.count)

            if data.isEmpty {
                DispatchQueue.main.async {
                    fileOffset = newOffset
                    isReading = false
                }
                return
            }

            let chunk = String(data: data, encoding: .utf8) ?? ""
            let merged = fragment + chunk
            var parts = merged.components(separatedBy: "\n")
            fragment = parts.popLast() ?? ""

            for raw in parts {
                guard let parsed = parseLine(raw, id: runningID) else { continue }
                lines.append(parsed)
                runningID += 1
            }

            if lines.count > maxRenderedLines {
                lines.removeFirst(lines.count - maxRenderedLines)
            }

            DispatchQueue.main.async {
                logLines = lines
                fileOffset = newOffset
                pendingFragment = fragment
                nextLineID = runningID
                isReading = false
            }
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            if !isPaused { loadLog() }
        }
    }

    private func copyFilteredLogs() {
        let text = filteredLines.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func parseLine(_ raw: String, id: Int) -> ParsedLogLine? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if let data = line.data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONLogLine.self, from: data) {
            let normalizedTs = LogTimestampFormatter.normalizeTimestamp(json.ts)
            let text = "[\(normalizedTs)] [\(json.level)] [\(json.channel)] \(json.message)"
            return ParsedLogLine(
                id: "\(id)-\(normalizedTs)-\(json.level)-\(json.channel)",
                text: text,
                level: json.level,
                channel: json.channel
            )
        }

        let normalizedLine = LogTimestampFormatter.normalizeLinePrefix(line)
        let level = ["DEBUG", "INFO", "WARN", "ERROR"].first { line.contains("[\($0)]") }
        let channel = ["PRIMARY", "FILEIO", "DIAG"].first { line.contains("[\($0)]") }
        return ParsedLogLine(
            id: "\(id)-legacy-\(line.hashValue)",
            text: normalizedLine,
            level: level,
            channel: channel
        )
    }
}

// MARK: - 关于页

private struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                LinearGradient(
                    colors: [Color.orange, Color(red: 0.95, green: 0.2, blue: 0.35)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
    }
}

private struct AboutTab: View {
    @Environment(HelperClient.self) private var helperClient
    @State private var helperVersion = "—"

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // App 头部信息
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                HStack(alignment: .center, spacing: 8) {
                    Text("ClawdHome")
                        .font(.title2)
                        .fontWeight(.semibold)
                    BetaBadge()
                }
            }
            .padding(.bottom, 4)

            Divider()

            GroupBox("XPC 连接") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(helperClient.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(helperClient.isConnected ? "已连接" : "未连接")
                        Spacer()
                        if !helperClient.isConnected {
                            Text("请运行 sudo scripts/install-helper-dev.sh")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if helperClient.isConnected {
                        LabeledContent("Helper 版本", value: helperVersion)
                        LabeledContent("App 版本", value: appVersion)
                    }
                }
                .padding(4)
            }
            Link(destination: URL(string: "https://clawdhome.app")!) {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                    Text("ClawdHome.app")
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Link(destination: URL(string: "https://ClawdHome.app/docs")!) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                    Text("文档")
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Spacer()
        }
        .task {
            if helperClient.isConnected {
                helperVersion = (try? await helperClient.getVersion()) ?? "未知"
            }
        }
    }
}
