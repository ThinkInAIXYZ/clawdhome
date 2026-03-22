// ClawdHome/Views/UserListView.swift
// 文件名保留，struct 名为 ClawPoolView

import Darwin
import SwiftUI

struct ClawPoolView: View {
    var onLoadUsers: () -> Void = {}

    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self)   private var pool
    @Environment(UpdateChecker.self) private var updater
    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @State private var selectedClaw: ManagedUser.ID?
    @State private var showAddSheet = false
    @State private var createUserError: String?
    @State private var isCreatingUser = false
    @AppStorage("clawPoolIsCardView") private var isCardView = true
    @AppStorage("clawPoolShowCurrentAdmin") private var showCurrentAdmin = false
    @Environment(\.openWindow) private var openWindow

    // MARK: 右键菜单 — 快速操作
    @State private var quickActionError: String?

    // MARK: 右键菜单 — 工具 sheet（枚举合并避免类型检查超时）
    @State private var toolSheet: ToolSheet?
    @State private var cloneClawSourceUser: ManagedUser?

    // MARK: 右键菜单 — 删除流程（item: 绑定，避免 isPresented+可选值 时序 bug）
    @State private var contextMenuUser: ManagedUser?
    @State private var contextDeleteOption: DeleteHomeOption = .deleteHome
    @State private var contextDeleteAdminPassword = ""
    @State private var contextDeleteError: String?
    @State private var contextDeleteStep: DeleteStep?
    @State private var contextIsDeleting = false
    @State private var pendingFlashFreezeClawID: ManagedUser.ID?
    private var currentUsername: String { NSUserName() }
    /// 默认仅展示标准用户；可在设置中显式开启当前管理员展示。
    private var displayedUsers: [ManagedUser] {
        pool.users.filter {
            ClawPoolVisibilityPolicy.shouldShowUser(
                username: $0.username,
                isAdmin: $0.isAdmin,
                currentUsername: currentUsername,
                showCurrentAdmin: showCurrentAdmin
            )
        }
    }

    private var selectedUser: ManagedUser? {
        guard let id = selectedClaw else { return nil }
        return displayedUsers.first { $0.id == id }
    }

    @ViewBuilder
    private func toolSheetContent(_ sheet: ToolSheet) -> some View {
        switch sheet {
        case .log(let u):      LogViewerSheet(username: u)
        case .password(let u): UserPasswordSheet(username: u)
        }
    }

    var body: some View {
        baseContent
            .sheet(item: $toolSheet, content: toolSheetContent)
            .sheet(item: $cloneClawSourceUser) { claw in
                CloneClawSheet(sourceUsername: claw.username)
            }
            .sheet(item: $contextMenuUser) { claw in
                DeleteUserSheet(
                    username: claw.username,
                    adminUser: NSUserName(),
                    option: $contextDeleteOption,
                    adminPassword: $contextDeleteAdminPassword,
                    isDeleting: contextIsDeleting,
                    error: contextDeleteError,
                    onConfirm: {
                        Task { await performContextDelete(for: claw) }
                    },
                    onCancel: {
                        contextMenuUser = nil
                        contextDeleteError = nil
                        contextDeleteAdminPassword = ""
                    }
                )
                .interactiveDismissDisabled(contextIsDeleting)
            }
    }

    // 主体内容（拆出来避免 body 类型检查超时）
    private var baseContent: some View {
        Group {
            if isCardView { cardContent } else { tableContent }
        }
        // 点击行/卡片时打开独立详情窗口（同一用户已开则置前）
        .onChange(of: selectedClaw) { _, newValue in
            guard let id = newValue,
                  let claw = displayedUsers.first(where: { $0.id == id }) else { return }
            openWindow(id: "claw-detail", value: claw.username)
            // 短暂延迟后取消选中，避免行持续高亮
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                selectedClaw = nil
            }
        }
        .onChange(of: showCurrentAdmin) { _, _ in
            if let selected = selectedClaw,
               !displayedUsers.contains(where: { $0.id == selected }) {
                selectedClaw = nil
            }
        }
        .navigationTitle("虾塘")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("视图模式", selection: $isCardView) {
                    Label("卡片", systemImage: "square.grid.2x2").tag(true)
                    Label("列表", systemImage: "list.bullet").tag(false)
                }
                .pickerStyle(.segmented)
                .help(isCardView ? "切换到列表视图" : "切换到卡片视图")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: { Label("添加", systemImage: "plus") }
                    .disabled(isCreatingUser)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddClawSheet { username, fullName, description in
                Task {
                    isCreatingUser = true
                    createUserError = nil
                    do {
                        let password = try UserPasswordStore.generateAndSave(for: username)
                        try await helperClient.createUser(
                            username: username, fullName: fullName, password: password)
                        pool.loadUsers()
                        pool.setDescription(description, for: username)
                        // 新用户创建后立即打开详情窗口，稳定进入初始化向导；
                        // 不依赖异步 loadUsers 完成后的选中态时序。
                        openWindow(id: "claw-detail", value: username)
                    } catch { createUserError = error.localizedDescription }
                    isCreatingUser = false
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let err = createUserError ?? quickActionError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
            }
        }
        .confirmationDialog(
            "确认速冻",
            isPresented: Binding(
                get: { pendingFlashFreezeClawID != nil },
                set: { newValue in
                    if !newValue { pendingFlashFreezeClawID = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("速冻", role: .destructive) {
                guard let id = pendingFlashFreezeClawID,
                      let claw = displayedUsers.first(where: { $0.id == id }) else {
                    pendingFlashFreezeClawID = nil
                    return
                }
                pendingFlashFreezeClawID = nil
                Task { await freezeClaw(claw, mode: .flash) }
            }
            Button("取消", role: .cancel) {
                pendingFlashFreezeClawID = nil
            }
        } message: {
            Text("将紧急终止该虾的用户空间进程（优先 openclaw 相关），已终止进程不可恢复，只能重新启动。")
        }
    }

    // MARK: - 右键菜单内容

    @ViewBuilder
    private func clawContextMenu(for claw: ManagedUser) -> some View {
        let readiness = gatewayHub.readinessMap[claw.username]
        let isRunning = readiness == .ready || readiness == .starting || claw.isRunning
        gatewayMenuItems(for: claw, isRunning: isRunning, isFrozen: claw.isFrozen)
        Divider()
        sessionMenuItems(for: claw)
        Divider()
        toolMenuItems(for: claw)
        if !claw.isAdmin {
            Divider()
            dangerMenuItems(for: claw, isRunning: isRunning)
        }
    }

    @ViewBuilder
    private func gatewayMenuItems(for claw: ManagedUser, isRunning: Bool, isFrozen: Bool) -> some View {
        if claw.openclawVersion != nil {
            if isFrozen {
                Button { Task { await unfreezeClaw(claw) } } label: {
                    Label("解除冻结", systemImage: "snowflake.slash")
                }
                if claw.hasFreezeWarning, let mode = claw.freezeMode {
                    if mode == .flash {
                        Button(role: .destructive) {
                            pendingFlashFreezeClawID = claw.id
                        } label: {
                            Label("重新执行\(mode.title)", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        }
                    } else {
                        Button {
                            Task { await freezeClaw(claw, mode: mode) }
                        } label: {
                            Label("重新执行\(mode.title)", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        }
                    }
                }
            } else {
                if !isRunning {
                    Button {
                        Task {
                            gatewayHub.markPendingStart(username: claw.username)
                            do {
                                try await helperClient.startGateway(username: claw.username)
                                claw.isRunning = true
                            } catch { quickActionError = "启动失败：\(error.localizedDescription)" }
                        }
                    } label: { Label("启动 Gateway", systemImage: "play.fill") }
                } else {
                    Button {
                        Task {
                            do {
                                try await helperClient.stopGateway(username: claw.username)
                                claw.isRunning = false
                            } catch { quickActionError = "停止失败：\(error.localizedDescription)" }
                        }
                    } label: { Label("停止 Gateway", systemImage: "stop.fill") }

                    Button {
                        Task {
                            do { try await helperClient.restartGateway(username: claw.username) }
                            catch { quickActionError = "重启失败：\(error.localizedDescription)" }
                        }
                    } label: { Label("重启 Gateway", systemImage: "arrow.clockwise") }
                }

                Divider()
                Menu("冻结…") {
                    Button {
                        Task { await freezeClaw(claw, mode: .pause) }
                    } label: { Label("暂停冻结（可恢复）", systemImage: "pause.circle") }
                    Button {
                        Task { await freezeClaw(claw, mode: .normal) }
                    } label: { Label("普通冻结（停止 Gateway）", systemImage: "snowflake") }
                    Button(role: .destructive) {
                        pendingFlashFreezeClawID = claw.id
                    } label: { Label("速冻（紧急终止进程）", systemImage: "bolt.fill") }
                }
            }
            Button { Task { await openWebUI(for: claw) } } label: {
                Label("打开 Web UI", systemImage: "globe")
            }
            .disabled(claw.isFrozen)
        }
    }

    @ViewBuilder
    private func sessionMenuItems(for claw: ManagedUser) -> some View {
        Button {
            openWindow(id: "claw-detail", value: claw.username)
        } label: { Label("在新窗口打开", systemImage: "macwindow.on.rectangle") }

        Button { openTerminal(for: claw) } label: {
            Label("打开终端", systemImage: "terminal")
        }
    }

    @ViewBuilder
    private func toolMenuItems(for claw: ManagedUser) -> some View {
        Button { toolSheet = .log(claw.username)      } label: { Label("查看日志", systemImage: "doc.text")      }
        Button { toolSheet = .password(claw.username) } label: { Label("查看密码", systemImage: "key")           }
        Button { cloneClawSourceUser = claw } label: {
            Label("克隆新虾…", systemImage: "doc.on.doc")
        }
        .disabled(claw.openclawVersion == nil)
    }

    @ViewBuilder
    private func dangerMenuItems(for claw: ManagedUser, isRunning: Bool) -> some View {
        if isRunning {
            Button(role: .destructive) {
                Task {
                    do {
                        try await helperClient.logoutUser(username: claw.username)
                        claw.isRunning = false
                    } catch { quickActionError = "注销失败：\(error.localizedDescription)" }
                }
            } label: { Label("注销会话", systemImage: "arrow.uturn.left") }
            Divider()
        }
        Button(role: .destructive) {
            contextDeleteOption = .deleteHome
            contextDeleteAdminPassword = ""
            contextDeleteError = nil
            contextMenuUser = claw   // 设置 item，sheet 自动弹出
        } label: { Label("删除用户…", systemImage: "trash") }
    }

    // MARK: - 列表视图

    private var tableContent: some View {
        Table(displayedUsers, selection: $selectedClaw) {
            TableColumn("") { claw in
                Image(systemName: claw.clawType.icon)
                    .foregroundStyle(.secondary)
            }
            .width(24)

            TableColumn("名称") { claw in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(claw.fullName.isEmpty ? claw.username : claw.fullName)
                            .fontWeight(.medium)
                        if claw.isAdmin {
                            Text("管理员")
                                .font(.caption2).fontWeight(.medium)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.85), in: Capsule())
                        }
                    }
                    if !claw.profileDescription.isEmpty {
                        Text(claw.profileDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    openWindow(id: "claw-detail", value: claw.username)
                }
            }
            .width(min: 100, ideal: 140)

            TableColumn("类型") { claw in
                Text(claw.clawType.displayName).foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("副标识") { claw in
                Text(claw.identifier)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)

            TableColumn("版本") { claw in
                if let v = claw.openclawVersionLabel {
                    HStack(spacing: 3) {
                        Text(v).monospacedDigit()
                            .foregroundStyle(updater.needsUpdate(claw.openclawVersion) ? .orange : .primary)
                        if updater.needsUpdate(claw.openclawVersion) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .help(updater.needsUpdate(claw.openclawVersion)
                          ? "可升级到 v\(updater.latestVersion ?? "")"
                          : "")
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(110)

            TableColumn("状态") { claw in
                clawStatusView(claw)
            }
            .width(90)

            TableColumn("运行时长") { claw in
                if let started = claw.startedAt {
                    Text(started, style: .relative).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(80)

            TableColumn("资源占用") { claw in
                let hasStorage = claw.openclawDirBytes > 0
                if claw.cpuPercent != nil || claw.memRssMB != nil || hasStorage {
                    HStack(spacing: 5) {
                        if let cpu = claw.cpuPercent {
                            HStack(spacing: 2) {
                                Image(systemName: "cpu").font(.system(size: 8)).foregroundStyle(.blue)
                                Text(String(format: "%.0f%%", cpu)).foregroundStyle(.blue)
                            }
                        }
                        if let mem = claw.memRssMB {
                            HStack(spacing: 2) {
                                Image(systemName: "memorychip").font(.system(size: 8)).foregroundStyle(.purple)
                                Text(mem >= 1024
                                     ? String(format: "%.1fG", mem / 1024)
                                     : String(format: "%.0fM", mem)).foregroundStyle(.purple)
                            }
                        }
                        if hasStorage {
                            HStack(spacing: 2) {
                                Image(systemName: "internaldrive").font(.system(size: 8)).foregroundStyle(.green)
                                Text(FormatUtils.formatBytes(claw.openclawDirBytes)).foregroundStyle(.green)
                            }
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(150)

            TableColumn("操作") { claw in
                HStack(spacing: 10) {
                    if claw.openclawVersion != nil {
                        Button { Task { await openWebUI(for: claw) } } label: {
                            Image(systemName: "globe").foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("打开 Web UI")
                    }
                    Button { openTerminal(for: claw) } label: {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("打开终端")
                }
            }
            .width(88)
        }
        .contextMenu(forSelectionType: ManagedUser.ID.self) { ids in
            if let id = ids.first,
               let claw = displayedUsers.first(where: { $0.id == id }) {
                clawContextMenu(for: claw)
            }
        }
    }

    // MARK: - 卡片视图

    private var cardContent: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 12)],
                spacing: 12
            ) {
                ForEach(displayedUsers) { claw in
                    ClawCard(
                        claw: claw,
                        isSelected: false
                    ) {
                        // 单击直接开详情窗口
                        openWindow(id: "claw-detail", value: claw.username)
                    } onDoubleClick: {
                        openWindow(id: "claw-detail", value: claw.username)
                    } onOpenWebUI: {
                        Task { await openWebUI(for: claw) }
                    } onTerminal: {
                        openTerminal(for: claw)
                    }
                    .contextMenu { clawContextMenu(for: claw) }
                }
                // 新增虾卡片
                AddClawCard { showAddSheet = true }
            }
            .padding(16)
        }
    }

    // MARK: - 共用状态视图

    @ViewBuilder
    private func clawStatusView(_ claw: ManagedUser) -> some View {
        if let step = claw.initStep {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, options: .repeating)
                    .font(.system(size: 9))
                Text(step).foregroundStyle(.secondary).font(.caption)
            }
        } else if claw.hasFreezeWarning {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 10, weight: .semibold))
                Text("冻结异常")
                    .foregroundStyle(.orange)
            }
            .help(claw.freezeWarning ?? "")
        } else if claw.isFrozen {
            let mode = claw.freezeMode ?? .normal
            HStack(spacing: 5) {
                Image(systemName: freezeSymbol(for: mode))
                    .foregroundStyle(freezeColor(for: mode))
                    .font(.system(size: 10, weight: .semibold))
                Text(mode.statusLabel)
                    .foregroundStyle(freezeColor(for: mode))
            }
        } else {
            let readiness = gatewayHub.readinessMap[claw.username] ?? (claw.isRunning ? .ready : .stopped)
            HStack(spacing: 5) {
                GatewayStatusDot(readiness: readiness)
                Text(readiness.label)
                    .foregroundStyle(readiness == .ready ? .primary : .secondary)
            }
        }
    }

    // MARK: - 右键删除流程

    private func performContextDelete(for claw: ManagedUser) async {
        contextIsDeleting = true
        contextDeleteError = nil

        contextDeleteStep = .deleting
        let keepHome = contextDeleteOption == .keepHome
        let adminPassword = contextDeleteAdminPassword
        contextDeleteAdminPassword = ""
        let targetUsername = claw.username

        do {
            // 直接执行 sysadminctl 删除（使用管理员凭据）
            try await deleteUserViaSysadminctl(username: targetUsername, keepHome: keepHome, adminPassword: adminPassword)

            contextDeleteStep = .done
            try? await Task.sleep(for: .milliseconds(700))
            if selectedClaw == claw.id { selectedClaw = nil }
            pool.removeUser(username: targetUsername)
            contextIsDeleting = false
            // contextMenuUser 已在 onConfirm 里清 nil，无需再清
        } catch {
            contextDeleteError = error.localizedDescription
            contextDeleteStep = nil
            contextIsDeleting = false
            contextMenuUser = claw   // 重新打开 sheet 显示错误
        }
    }

    private func verifyAdminPassword(user: String, password: String) async throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HelperError.operationFailed("请输入管理员登录密码")
        }
        try await Task.detached(priority: .userInitiated) {
            let nodes = ["/Local/Default", "/Search"]
            var lastError = "密码错误或无权限"

            for node in nodes {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
                proc.arguments = [node, "-authonly", user, trimmed]
                let pipe = Pipe()
                proc.standardError = pipe
                proc.standardOutput = pipe
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    return
                }
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !out.isEmpty { lastError = out }
            }

            throw HelperError.operationFailed("管理员密码校验失败：\(lastError)\n请填写该 macOS 账户的登录密码（不是用户名）")
        }.value
    }

    private func deleteUserViaSysadminctl(username: String, keepHome: Bool, adminPassword: String) async throws {
        let trimmed = adminPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HelperError.operationFailed("请输入管理员登录密码")
        }
        let timeoutSeconds: TimeInterval = 30

        try await Task.detached(priority: .userInitiated) {
            appLog("[user-delete] start @\(username) keepHome=\(keepHome)")

            let verifyArgs = ["-S", "-k", "-p", "", "-v"]
            let verify: (status: Int32, output: String)
            do {
                verify = try runProcessWithTimeout(
                    executable: "/usr/bin/sudo",
                    arguments: verifyArgs,
                    timeoutSeconds: timeoutSeconds,
                    stdin: "\(trimmed)\n"
                )
            } catch UserDeleteCommandError.timeout {
                appLog("[user-delete] command timeout @\(username)", level: .error)
                throw HelperError.operationFailed("管理员权限校验超时，请重试")
            }

            if verify.status != 0 {
                let verifyOutput = verify.output
                let normalized = verifyOutput.lowercased()
                if normalized.contains("incorrect password") || normalized.contains("sorry, try again") {
                    throw HelperError.operationFailed("管理员密码错误，请重试")
                }
                if !verifyOutput.isEmpty {
                    throw HelperError.operationFailed("管理员权限校验失败：\(verifyOutput)")
                }
                throw HelperError.operationFailed("管理员权限校验失败")
            }

            var sudoArgs = ["-S", "-p", "", "/usr/sbin/sysadminctl", "-deleteUser", username]
            if keepHome { sudoArgs.append("-keepHome") }
            let result = try runProcessWithTimeout(
                executable: "/usr/bin/sudo",
                arguments: sudoArgs,
                timeoutSeconds: timeoutSeconds,
                stdin: "\(trimmed)\n"
            )

            appLog("[user-delete] sysadminctl exit=\(result.status) outputBytes=\(result.output.utf8.count) @\(username)")
            if result.status != 0 {
                let output = result.output
                if output.lowercased().contains("unknown user") { return }
                if output.isEmpty {
                    throw HelperError.operationFailed("删除用户失败：sysadminctl exit \(result.status)")
                }
                throw HelperError.operationFailed("删除用户失败：\(output)")
            }

            if !waitForUserRecordRemoval(username: username, retries: 40, sleepMs: 250) {
                appLog("[user-delete] record still exists after command @\(username)", level: .warn)
                throw HelperError.operationFailed("删除用户 \(username) 后校验失败：系统记录仍存在")
            }
            appLog("[user-delete] success @\(username)")
        }.value
    }

    private nonisolated func waitForUserRecordRemoval(username: String, retries: Int, sleepMs: UInt32) -> Bool {
        for _ in 0..<retries {
            if !userRecordExists(username: username) { return true }
            flushDirectoryCache()
            usleep(sleepMs * 1_000)
        }
        return !userRecordExists(username: username)
    }

    private nonisolated func userRecordExists(username: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        proc.arguments = ["/Local/Default", "-read", "/Users/\(username)", "UniqueID"]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private nonisolated func flushDirectoryCache() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        proc.arguments = ["-flushcache"]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // best-effort
        }
    }

    private enum UserDeleteCommandError: LocalizedError {
        case timeout
        var errorDescription: String? {
            switch self {
            case .timeout: return "command timeout"
            }
        }
    }

    private nonisolated func runProcessWithTimeout(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        stdin: String? = nil
    ) throws -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let inputPipe = Pipe()
        proc.standardInput = inputPipe

        let lock = NSLock()
        var collected = Data()
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            collected.append(chunk)
            lock.unlock()
        }

        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        try proc.run()
        if let stdin {
            if let data = stdin.data(using: .utf8) {
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            }
        }
        inputPipe.fileHandleForWriting.closeFile()

        if sem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            if proc.isRunning { proc.terminate() }
            reader.readabilityHandler = nil
            throw UserDeleteCommandError.timeout
        }

        reader.readabilityHandler = nil
        let tail = reader.readDataToEndOfFile()
        lock.lock()
        collected.append(tail)
        let data = collected
        lock.unlock()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, output)
    }

    // MARK: - 打开 Web UI

    private func openWebUI(for claw: ManagedUser) async {
        guard !claw.isFrozen else {
            quickActionError = "@\(claw.username) \(claw.freezeMode?.statusLabel ?? "已冻结")，请先解除冻结再启动 Gateway"
            return
        }
        if !claw.isRunning {
            gatewayHub.markPendingStart(username: claw.username)
            try? await helperClient.startGateway(username: claw.username)
            claw.isRunning = true
        }
        let urlString = await helperClient.getGatewayURL(username: claw.username)
        if let url = URL(string: urlString), !urlString.isEmpty {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 打开终端

    private func openTerminal(for claw: ManagedUser) {
        let payload = maintenanceWindowRegistry.makePayload(
            username: claw.username,
            title: "命令行维护（高级）",
            command: ["zsh", "-l"]
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }

    private func freezeClaw(_ claw: ManagedUser, mode: FreezeMode) async {
        quickActionError = nil
        appLog("freeze start user=\(claw.username) mode=\(mode.statusLabel)")
        do {
            let previousAutostart = await helperClient.getUserAutostart(username: claw.username)
            try? await helperClient.setUserAutostart(username: claw.username, enabled: false)
            if mode != .pause {
                gatewayHub.markPendingStopped(username: claw.username)
                do {
                    try await helperClient.stopGateway(username: claw.username)
                } catch {
                    // 速冻为兜底路径：即使 stopGateway 失败也继续强制终止进程。
                    if mode != .flash { throw error }
                }
            }

            if mode == .pause {
                let processes = await helperClient.getProcessList(username: claw.username)
                let targets = ProcessEmergencyFreezeResolver.resolvePauseTargets(processes: processes)
                var pausedPIDs: [Int32] = []
                var failedPIDs: [Int32] = []
                for proc in targets {
                    do {
                        try await helperClient.killProcess(pid: proc.pid, signal: Int32(SIGSTOP))
                        pausedPIDs.append(proc.pid)
                    } catch {
                        failedPIDs.append(proc.pid)
                    }
                }
                if !failedPIDs.isEmpty {
                    let pidList = failedPIDs.prefix(8).map(String.init).joined(separator: ",")
                    throw HelperError.operationFailed("@\(claw.username) 暂停冻结部分失败，未挂起 PID: \(pidList)")
                }
                pool.setFrozen(
                    true,
                    mode: mode,
                    pausedPIDs: pausedPIDs,
                    previousAutostartEnabled: previousAutostart,
                    for: claw.username
                )
                appLog("freeze success user=\(claw.username) mode=\(mode.statusLabel) paused=\(pausedPIDs.count)")
                return
            }

            if mode == .flash {
                let processes = await helperClient.getProcessList(username: claw.username)
                let targets = ProcessEmergencyFreezeResolver.resolveTargets(processes: processes)
                var failedPIDs: [Int32] = []
                for proc in targets {
                    do {
                        try await helperClient.killProcess(pid: proc.pid, signal: 9)
                    } catch {
                        failedPIDs.append(proc.pid)
                    }
                }
                if !failedPIDs.isEmpty {
                    let pidList = failedPIDs.prefix(8).map(String.init).joined(separator: ",")
                    throw HelperError.operationFailed("@\(claw.username) 速冻部分失败，未终止 PID: \(pidList)")
                }
                // 二次 stop，防止状态滞后导致 launchd/job 被重新拉起。
                try? await helperClient.stopGateway(username: claw.username)
                // 速冻后立即复核：若关键进程被外部拉起，给出明确提示。
                try? await Task.sleep(for: .milliseconds(250))
                let remaining = await helperClient.getProcessList(username: claw.username)
                    .filter(ProcessEmergencyFreezeResolver.isOpenclawRelated)
                if !remaining.isEmpty {
                    let pidList = remaining.prefix(8).map { String($0.pid) }.joined(separator: ",")
                    throw HelperError.operationFailed("@\(claw.username) 速冻后检测到进程仍在运行（可能被自动拉起），PID: \(pidList)")
                }
            }
            pool.setFrozen(
                true,
                mode: mode,
                pausedPIDs: [],
                previousAutostartEnabled: previousAutostart,
                for: claw.username
            )
            appLog("freeze success user=\(claw.username) mode=\(mode.statusLabel)")
        } catch {
            quickActionError = "@\(claw.username) \(mode.title)失败：\(error.localizedDescription)"
            appLog("freeze failed user=\(claw.username) mode=\(mode.statusLabel) error=\(error.localizedDescription)", level: .error)
        }
    }

    private func unfreezeClaw(_ claw: ManagedUser) async {
        quickActionError = nil
        let mode = claw.freezeMode
        let pausedPIDs = claw.pausedProcessPIDs
        appLog("unfreeze start user=\(claw.username) mode=\(mode?.statusLabel ?? "未知")")
        do {
            if mode == .pause, !pausedPIDs.isEmpty {
                var failedPIDs: [Int32] = []
                for pid in pausedPIDs {
                    do {
                        try await helperClient.killProcess(pid: pid, signal: Int32(SIGCONT))
                    } catch {
                        failedPIDs.append(pid)
                    }
                }
                if !failedPIDs.isEmpty {
                    let pidList = failedPIDs.prefix(8).map(String.init).joined(separator: ",")
                    throw HelperError.operationFailed("@\(claw.username) 解除暂停部分失败，未恢复 PID: \(pidList)")
                }
            }
            if let restoreAutostart = claw.freezePreviousAutostartEnabled {
                try? await helperClient.setUserAutostart(username: claw.username, enabled: restoreAutostart)
            }
            pool.setFrozen(false, for: claw.username)
            appLog("unfreeze success user=\(claw.username)")
        } catch {
            quickActionError = "@\(claw.username) 解除冻结失败：\(error.localizedDescription)"
            appLog("unfreeze failed user=\(claw.username) error=\(error.localizedDescription)", level: .error)
        }
    }

    private func freezeSymbol(for mode: FreezeMode) -> String {
        switch mode {
        case .pause: "pause.circle"
        case .normal: "snowflake"
        case .flash: "bolt.fill"
        }
    }

    private func freezeColor(for mode: FreezeMode) -> Color {
        switch mode {
        case .pause: .blue
        case .normal: .cyan
        case .flash: .orange
        }
    }

}

// MARK: - 右键工具 Sheet 枚举

private enum ToolSheet: Identifiable {
    case log(String)
    case password(String)

    var id: String {
        switch self {
        case .log(let u):      "log-\(u)"
        case .password(let u): "pw-\(u)"
        }
    }
}

// MARK: - 虾卡片

private struct ClawCard: View {
    let claw: ManagedUser
    let isSelected: Bool
    let onTap: () -> Void
    var onDoubleClick: (() -> Void)? = nil
    let onOpenWebUI: () -> Void
    let onTerminal: () -> Void

    @Environment(UpdateChecker.self) private var updater

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                // 图标 + 状态角标
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: claw.clawType.icon)
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                    statusDot
                }

                // 名称
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(claw.fullName.isEmpty ? claw.username : claw.fullName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if claw.isAdmin {
                            Image(systemName: "shield.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text("@\(claw.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !claw.profileDescription.isEmpty {
                        Text(claw.profileDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // 副标签（版本 / 初始化步骤 / 未初始化）
                Group {
                    if claw.hasFreezeWarning {
                        Label("冻结异常", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(claw.freezeWarning ?? "")
                    } else if claw.isFrozen {
                        let mode = claw.freezeMode ?? .normal
                        Label(mode.statusLabel, systemImage: freezeSymbol(mode))
                            .foregroundStyle(freezeColor(mode))
                    } else if let step = claw.initStep {
                        Text(step).foregroundStyle(.blue)
                    } else if let v = claw.openclawVersionLabel {
                        let outdated = updater.needsUpdate(claw.openclawVersion)
                        HStack(spacing: 2) {
                            Text(v).monospacedDigit()
                                .foregroundStyle(outdated ? Color.orange : Color.secondary.opacity(0.6))
                            if outdated {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(Color.orange)
                            }
                        }
                    } else {
                        Text("未初始化").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
                .lineLimit(1)

                // 操作按钮行
                HStack(spacing: 8) {
                    if claw.openclawVersion != nil {
                        Button { onOpenWebUI() } label: {
                            Image(systemName: "globe")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("打开 Web UI")
                        .disabled(claw.isFrozen)
                    }
                    Button { onTerminal() } label: {
                        Image(systemName: "terminal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("打开终端")
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.08)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .saturation(claw.isFrozen ? saturationForFrozen(mode: claw.freezeMode ?? .normal) : 1)
            .overlay {
                if claw.isFrozen {
                    let mode = claw.freezeMode ?? .normal
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    freezeColor(mode).opacity(0.20),
                                    Color.white.opacity(0.06),
                                    freezeShadowColor(mode).opacity(0.16)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        claw.isFrozen
                            ? freezeColor(claw.freezeMode ?? .normal).opacity(0.8)
                            : (isSelected ? Color.accentColor : Color.secondary.opacity(0.18)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            onDoubleClick?()
        })
    }

    @Environment(GatewayHub.self) private var gatewayHub

    @ViewBuilder
    private var statusDot: some View {
        if claw.isFrozen {
            let mode = claw.freezeMode ?? .normal
            Image(systemName: freezeSymbol(mode))
                .foregroundStyle(freezeColor(mode))
                .font(.system(size: 10, weight: .semibold))
        } else if let _ = claw.initStep {
            Image(systemName: "circle.fill")
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, options: .repeating)
                .font(.system(size: 9))
        } else {
            let readiness = gatewayHub.readinessMap[claw.username] ?? (claw.isRunning ? .ready : .stopped)
            GatewayStatusDot(readiness: readiness)
        }
    }

    private func freezeSymbol(_ mode: FreezeMode) -> String {
        switch mode {
        case .pause: "pause.circle"
        case .normal: "snowflake"
        case .flash: "bolt.fill"
        }
    }

    private func freezeColor(_ mode: FreezeMode) -> Color {
        switch mode {
        case .pause: .blue
        case .normal: .cyan
        case .flash: .orange
        }
    }

    private func freezeShadowColor(_ mode: FreezeMode) -> Color {
        switch mode {
        case .pause: .indigo
        case .normal: .blue
        case .flash: .red
        }
    }

    private func saturationForFrozen(mode: FreezeMode) -> Double {
        switch mode {
        case .pause: 0.25
        case .normal: 0.12
        case .flash: 0.04
        }
    }
}

// MARK: - 新增虾卡片

private struct AddClawCard: View {
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Text("🦞")
                    .font(.system(size: 28))
                Text("领养虾苗")
                    .font(.caption)
                    .foregroundStyle(isHovered ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160)
            .background(
                isHovered
                    ? Color.accentColor.opacity(0.06)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .foregroundStyle(
                        isHovered ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 添加 Claw 流程

/// 顶层 sheet：NavigationStack 内先选类型，再进入具体表单
private struct AddClawSheet: View {
    /// macOS 用户创建回调 (username, fullName, description)
    let onCreateMacosUser: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [ClawType] = []

    var body: some View {
        NavigationStack(path: $path) {
            List(ClawType.allCases, id: \.self) { type in
                Button {
                    path.append(type)
                } label: {
                    Label(type.displayName, systemImage: type.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .navigationTitle("选择类型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .navigationDestination(for: ClawType.self) { clawType in
                switch clawType {
                case .macosUser:
                    AddMacosUserForm { username, fullName, description in
                        onCreateMacosUser(username, fullName, description)
                        dismiss()
                    }
                default:
                    VStack {
                        Spacer()
                        Image(systemName: clawType.icon)
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("\(clawType.displayName) 即将支持")
                            .font(.title2).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                        Text("敬请期待")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("添加 \(clawType.displayName)")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("添加") { }.disabled(true)
                        }
                    }
                }
            }
        }
        .frame(width: 440, height: 500)
    }
}

/// macOS 标准用户创建表单
private struct AddMacosUserForm: View {
    let onConfirm: (String, String, String) -> Void

    @State private var username = ""
    @State private var fullName = ""
    @State private var descriptionText = ""

    private var usernameValid: Bool {
        username.range(of: #"^[a-z_][a-z0-9_]{0,31}$"#, options: .regularExpression) != nil
    }
    private var isValid: Bool { usernameValid }

    var body: some View {
        Form {
            Section {
                TextField("用户名", text: $username)
                    .textContentType(.username)
                if !username.isEmpty && !usernameValid {
                    Text("用户名只能包含小写字母、数字和下划线，且须以字母开头")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField("全名（显示用）", text: $fullName)
                TextField("描述（可选，用于备注用途）", text: $descriptionText)
            } header: { Text("账户信息") }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: "lock.rotation")
                        .foregroundStyle(.secondary)
                    Text("密码将自动随机生成并安全存储，可在用户详情中查看")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: { Text("密码") }
        }
        .formStyle(.grouped)
        .navigationTitle("添加 macOS 用户")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("创建") {
                    onConfirm(username, fullName.isEmpty ? username : fullName, descriptionText)
                }
                .disabled(!isValid)
            }
        }
    }
}

/// SSH Claw 样例表单（逻辑未实现，提交按钮禁用）
private struct AddSSHSampleForm: View {
    @State private var host = ""
    @State private var sshUser = ""
    @State private var port = "22"
    @State private var identityFile = ""

    var body: some View {
        Form {
            Section {
                TextField("主机名 / IP", text: $host)
                TextField("SSH 用户名", text: $sshUser)
                TextField("端口", text: $port)
            } header: { Text("连接信息") }

            Section {
                TextField("私钥路径（可选）", text: $identityFile)
            } header: { Text("认证") }

            Section {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("SSH 类型的 Claw 即将支持，目前仅作预览展示")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("添加 SSH Claw")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // 即将支持，暂时禁用
                Button("添加") { }.disabled(true)
            }
        }
    }
}
