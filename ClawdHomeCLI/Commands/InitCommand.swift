// ClawdHomeCLI/Commands/InitCommand.swift
// 初始化编排命令：init run / status / resume / cancel

import Foundation
import Darwin

enum InitCommand {

    static func run(_ args: [String], client: CLIHelperClient) throws {
        guard let sub = args.first else {
            printUsage()
            exit(1)
        }

        let rest = Array(args.dropFirst())
        switch sub {
        case "run":
            try runInit(rest, client: client)
        case "status":
            try status(rest, client: client)
        case "resume":
            try resume(rest, client: client)
        case "cancel":
            try cancel(rest, client: client)
        case "-h", "--help":
            printUsage()
        default:
            Output.printError("未知 init 子命令: \(sub)")
            printUsage()
            exit(1)
        }
    }

    private static func printUsage() {
        Output.printErr("""
        ClawdHome Init — Shrimp 初始化流程

        用法: clawdhome init <command> [args]

        Commands:
          run <name> [options]       执行初始化流程
          status <name>              查看初始化状态
          resume <name> [options]    从中断点继续初始化
          cancel <name>              取消初始化（会终止安装进程）

        run/resume Options:
          --full-name <name>         全名（仅 run 生效，默认同用户名）
          --password <pw>            用户密码（仅 run 生效，默认随机）
          --config <path>            初始化配置文件（JSON）
          --version <v|latest>       openclaw 版本（默认 latest）
          --npm-registry <url>       npm 安装源（默认淘宝镜像）
          --proxy <url>              HTTP 代理（写入用户环境变量）
          --no-proxy <hosts>         代理排除列表（配合 --proxy 使用）
          --start-gateway            初始化完成后启动 gateway
          --skip-persona-finalize    仅写入 pending_v2_agents.json，不写工作区 persona 文件
          --interactive-binding      交互询问是否执行飞书/微信扫码绑定
          --bind-feishu              执行飞书扫码绑定（npx lark-tools install）
          --bind-weixin              执行微信扫码绑定（npx weixin-cli install）
          --bind-wechat              --bind-weixin 的别名
          --verify-chat              初始化后执行一次 chat 验证
          --verify-chat-message <m>  chat 验证消息（默认"请简短回复：初始化验证成功"）
          --verify-chat-session <k>  chat 验证 session key（默认 default）
          --verify-chat-timeout <s>  chat 验证超时秒数（默认 120）

        配置文件支持两种格式：
          1) 直接 ShrimpConfigV2 JSON
          2) 包装对象:
             {
               "config": { ...ShrimpConfigV2... },
               "personas": [{ "agentDefId": "main", "dna": {...} }]
             }
        """)
    }

    // MARK: - 默认 TOOLS.md 内容（与 UI 侧 UserInitWizardView.defaultToolsContent 保持一致）

    static let defaultToolsContent = """
    ## Shared Folders

    You have two file sharing spaces accessible at the following paths:

    ### Private Folder
    - Path: `~/clawdhome_shared/private/`
    - Access: Only you and the admin can access; other Shrimps cannot see it
    - Purpose: All work outputs, generated files, and exported data should be stored here first

    ### Public Folder
    - Path: `~/clawdhome_shared/public/`
    - Access: Shared by all Shrimps and the admin
    - Purpose: Read/write common resources, shared files, and public datasets

    ### Usage Guidelines
    - When asked to save files, export results, or generate reports, write to `~/clawdhome_shared/private/`
    - When referencing public resources, read from `~/clawdhome_shared/public/`
    - Do not write sensitive data to the public folder
    """
    static let sharedFolderMarker = "~/clawdhome_shared/"

    // MARK: - run

    private static func runInit(_ args: [String], client: CLIHelperClient) throws {
        let opts = try parseRunLikeOptions(args, command: "run")
        try executePipeline(options: opts, isResume: false, client: client)
    }

    // MARK: - resume

    private static func resume(_ args: [String], client: CLIHelperClient) throws {
        let opts = try parseRunLikeOptions(args, command: "resume")
        try executePipeline(options: opts, isResume: true, client: client)
    }

    // MARK: - status

    private static func status(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first, !username.isEmpty else {
            Output.printError("用法: clawdhome init status <name>")
            exit(1)
        }
        let proxy = try client.proxy()
        let raw = syncCallString { proxy.loadInitState(username: username, withReply: $0) }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if Output.jsonMode {
                Output.printJSON([
                    "name": username,
                    "exists": false,
                ] as [String: Any])
            } else {
                Output.printErr("未找到 \(username) 的初始化状态")
            }
            return
        }

        let state = CLIInitState.from(json: raw)
        if Output.jsonMode {
            if let state {
                Output.printJSON([
                    "name": username,
                    "exists": true,
                    "active": state.active,
                    "currentPhase": state.cliCurrentPhase ?? "",
                    "phases": state.cliPhases,
                    "currentStep": state.currentStep ?? "",
                    "steps": state.steps,
                    "updatedAt": iso8601String(state.updatedAt),
                    "completedAt": state.completedAt.map(iso8601String) as Any,
                ] as [String: Any])
            } else {
                Output.printJSON([
                    "name": username,
                    "exists": true,
                    "raw": raw,
                ] as [String: Any])
            }
            return
        }

        guard let state else {
            print("Name:        \(username)")
            print("State:       无法解析（原始 JSON）")
            print("Raw:         \(raw)")
            return
        }

        print("Name:        \(username)")
        print("Active:      \(state.active ? "yes" : "no")")
        print("CurrentStep: \(state.currentStep ?? "-")")
        print("CurrentPhase:\(state.cliCurrentPhase ?? "-")")
        print("UpdatedAt:   \(iso8601String(state.updatedAt))")
        if let completedAt = state.completedAt {
            print("CompletedAt: \(iso8601String(completedAt))")
        }
        if !state.cliPhases.isEmpty {
            print("")
            let rows = InitCLIPhase.allCases.map {
                [$0.rawValue, state.cliPhases[$0.rawValue] ?? "pending"]
            }
            Output.printTable(headers: ["PHASE", "STATUS"], rows: rows)
        }
    }

    // MARK: - cancel

    private static func cancel(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first, !username.isEmpty else {
            Output.printError("用法: clawdhome init cancel <name>")
            exit(1)
        }

        let proxy = try client.proxy()
        let cancelled = syncCallBool { proxy.cancelInit(username: username, withReply: $0) }
        if !cancelled {
            throw CLIError.operationFailed("取消初始化失败")
        }

        var state = loadState(proxy: proxy, username: username) ?? CLIInitState()
        state.active = false
        state.cliCurrentPhase = nil
        state.stepErrors["cancelled"] = "cancelled by CLI"
        state.updatedAt = Date()
        try saveState(proxy: proxy, username: username, state: state)

        if Output.jsonMode {
            Output.printJSON([
                "name": username,
                "cancelled": true,
            ] as [String: Any])
        } else {
            Output.printSuccess("初始化已取消: \(username)")
        }
    }

    // MARK: - Pipeline

    private static func executePipeline(
        options: InitRunOptions,
        isResume: Bool,
        client: CLIHelperClient
    ) throws {
        if Output.jsonMode && options.interactiveBinding {
            throw CLIError.operationFailed("--interactive-binding 不支持 --json 输出")
        }
        if Output.jsonMode && options.verifyChat {
            throw CLIError.operationFailed("--verify-chat 不支持 --json 输出")
        }

        let proxy = try client.proxy()
        let shouldStartGateway = options.startGateway || options.verifyChat

        var state: CLIInitState
        if let existing = loadState(proxy: proxy, username: options.username) {
            state = existing
            if !isResume && existing.active {
                throw CLIError.operationFailed("检测到未完成初始化，请改用: clawdhome init resume \(options.username)")
            }
            if isResume && !existing.active && existing.completedAt != nil {
                throw CLIError.operationFailed("初始化已完成，无需 resume")
            }
        } else {
            if isResume {
                throw CLIError.operationFailed("没有可恢复的初始化状态，请先运行: clawdhome init run \(options.username)")
            }
            state = CLIInitState()
        }

        state.active = true
        state.mode = "onboarding"
        state.openclawVersion = options.openclawVersionForState
        if let configPath = options.configPath, !configPath.isEmpty {
            state.cliConfigPath = configPath
        }
        state.updatedAt = Date()
        try saveState(proxy: proxy, username: options.username, state: state)

        let plan = try loadPlan(options: options, state: state)
        var mutableState = state
        var didCreateUser = false

        try runPhase(.createUser, state: &mutableState, username: options.username, proxy: proxy) {
            if try InstanceExists.check(options.username) {
                return
            }
            guard !isResume else {
                throw CLIError.operationFailed("实例不存在，无法 resume。请先重新执行 run")
            }
            let (ok, err) = syncCall2 {
                proxy.createUser(
                    username: options.username,
                    fullName: options.fullName,
                    password: options.password,
                    withReply: $0
                )
            }
            if !ok {
                throw CLIError.operationFailed("创建用户失败: \(err ?? "未知错误")")
            }
            didCreateUser = true
        }

        try runPhase(.setupWorkspace, state: &mutableState, username: options.username, proxy: proxy) {
            // 创建 workspace 目录
            let workspaceDir = ".openclaw/workspace"
            let (mkOK, mkErr) = syncCall2 {
                proxy.createDirectory(username: options.username, relativePath: workspaceDir, withReply: $0)
            }
            if !mkOK, let mkErr, !mkErr.isEmpty {
                throw CLIError.operationFailed("创建 workspace 目录失败: \(mkErr)")
            }

            // 注入 TOOLS.md
            let toolsPath = "\(workspaceDir)/TOOLS.md"
            let (existingData, _) = syncCallRead { proxy.readFile(username: options.username, relativePath: toolsPath, withReply: $0) }
            let existingContent = existingData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if !existingContent.contains(Self.sharedFolderMarker) {
                let toolsContent = existingContent.isEmpty
                    ? Self.defaultToolsContent
                    : existingContent + "\n\n" + Self.defaultToolsContent
                let (ok, err) = syncCallWrite {
                    proxy.writeFile(
                        username: options.username,
                        relativePath: toolsPath,
                        data: toolsContent.data(using: .utf8) ?? Data(),
                        withReply: $0
                    )
                }
                if !ok {
                    throw CLIError.operationFailed("写入 TOOLS.md 失败: \(err ?? "未知错误")")
                }
            }

            // 建立 shared/ 符号链接
            let (vaultOK, vaultErr) = syncCall2 {
                proxy.setupVault(username: options.username, withReply: $0)
            }
            if !vaultOK, let vaultErr, !vaultErr.isEmpty {
                logInit("setupVault 警告: \(vaultErr)", username: options.username)
            }

            // 应用代理设置
            if let proxyURL = options.proxyURL, !proxyURL.isEmpty {
                let (proxyOK, proxyErr) = syncCall2 {
                    proxy.applyProxySettings(
                        username: options.username,
                        enabled: true,
                        proxyURL: proxyURL,
                        noProxy: options.noProxy ?? "",
                        restartGatewayIfRunning: false,
                        withReply: $0
                    )
                }
                if !proxyOK {
                    throw CLIError.operationFailed("应用代理设置失败: \(proxyErr ?? "未知错误")")
                }
            }
        }

        try runPhase(.repairHomebrew, state: &mutableState, username: options.username, proxy: proxy) {
            // best-effort：失败不阻断
            let (_, err) = syncCall2 {
                proxy.repairHomebrewPermission(username: options.username, withReply: $0)
            }
            if let err {
                logInit("Homebrew 修复警告（不影响继续）: \(err)", username: options.username)
            }
        }

        try runPhase(.installNode, state: &mutableState, username: options.username, proxy: proxy) {
            let nodeReady = syncCallBool { proxy.isNodeInstalled(username: options.username, withReply: $0) }
            if nodeReady {
                return
            }
            let (ok, err) = syncCall2 {
                proxy.installNode(username: options.username, nodeDistURL: "", withReply: $0)
            }
            if !ok {
                throw CLIError.operationFailed("安装 Node.js 失败: \(err ?? "未知错误")")
            }
        }

        try runPhase(.setupNpmEnv, state: &mutableState, username: options.username, proxy: proxy) {
            let (ok, err) = syncCall2 {
                proxy.setupNpmEnv(username: options.username, withReply: $0)
            }
            if !ok {
                throw CLIError.operationFailed("配置 npm 环境失败: \(err ?? "未知错误")")
            }
        }

        try runPhase(.setNpmRegistry, state: &mutableState, username: options.username, proxy: proxy) {
            let (ok, err) = syncCall2 {
                proxy.setNpmRegistry(
                    username: options.username,
                    registry: options.npmRegistry,
                    withReply: $0
                )
            }
            if !ok {
                throw CLIError.operationFailed("设置 npm 安装源失败: \(err ?? "未知错误")")
            }
        }

        try runPhase(.installOpenclaw, state: &mutableState, username: options.username, proxy: proxy) {
            let currentVersion = syncCallString { proxy.getOpenclawVersion(username: options.username, withReply: $0) }
            if !currentVersion.isEmpty {
                return
            }
            let versionArg = options.openclawVersion == "latest" ? nil : options.openclawVersion
            let (ok, err) = syncCall2 {
                proxy.installOpenclaw(username: options.username, version: versionArg, withReply: $0)
            }
            if !ok {
                throw CLIError.operationFailed("安装 openclaw 失败: \(err ?? "未知错误")")
            }
        }

        try runPhase(.applyV2Config, state: &mutableState, username: options.username, proxy: proxy) {
            let configJSON = try plan.encodeConfigJSON()
            let (ok, err) = syncCall2 {
                proxy.applyV2Config(username: options.username, configJSON: configJSON, withReply: $0)
            }
            if !ok {
                throw CLIError.operationFailed("写入配置失败: \(err ?? "未知错误")")
            }
        }

        if plan.personas.isEmpty {
            mutableState.cliPhases[InitCLIPhase.stagePendingPersona.rawValue] = "skipped"
            mutableState.updatedAt = Date()
            try saveState(proxy: proxy, username: options.username, state: mutableState)
        } else {
            try runPhase(.stagePendingPersona, state: &mutableState, username: options.username, proxy: proxy) {
                try stagePendingPersonas(
                    username: options.username,
                    entries: plan.personas,
                    proxy: proxy
                )
            }
        }

        if shouldStartGateway {
            try runPhase(.startGateway, state: &mutableState, username: options.username, proxy: proxy) {
                let (ok, err) = syncCall2 { proxy.startGateway(username: options.username, withReply: $0) }
                if !ok {
                    throw CLIError.operationFailed("启动 gateway 失败: \(err ?? "未知错误")")
                }
            }
        } else {
            mutableState.cliPhases[InitCLIPhase.startGateway.rawValue] = "skipped"
            mutableState.updatedAt = Date()
            try saveState(proxy: proxy, username: options.username, state: mutableState)
        }

        if plan.personas.isEmpty || !options.finalizePersona {
            mutableState.cliPhases[InitCLIPhase.finalizePersona.rawValue] = plan.personas.isEmpty ? "skipped" : "disabled"
            mutableState.updatedAt = Date()
            try saveState(proxy: proxy, username: options.username, state: mutableState)
        } else {
            try runPhase(.finalizePersona, state: &mutableState, username: options.username, proxy: proxy) {
                try finalizePersonasFromPending(username: options.username, proxy: proxy)
            }
        }

        let bindingPlan = try resolveBindingPlan(options: options, username: options.username)
        if bindingPlan.hasAny {
            try performChannelBindings(plan: bindingPlan, username: options.username, proxy: proxy)
        } else {
            logInit("跳过 IM 扫码绑定", username: options.username)
        }

        if options.verifyChat {
            try runChatVerification(options: options, client: client)
        } else {
            logInit("跳过 chat 验证", username: options.username)
        }

        mutableState.active = false
        mutableState.currentStep = InitStepCompat.finish.rawValue
        mutableState.steps[InitStepCompat.finish.rawValue] = "done"
        mutableState.cliCurrentPhase = nil
        mutableState.completedAt = Date()
        mutableState.updatedAt = Date()
        try saveState(proxy: proxy, username: options.username, state: mutableState)

        if Output.jsonMode {
            var payload: [String: Any] = [
                "name": options.username,
                "created": didCreateUser,
                "startGateway": shouldStartGateway,
                "personaFinalized": options.finalizePersona,
                "requestedBindings": bindingPlan.channels,
                "chatVerified": options.verifyChat,
                "success": true,
            ]
            if didCreateUser {
                payload["password"] = options.password
            }
            Output.printJSON(payload)
        } else {
            Output.printSuccess("初始化完成: \(options.username)")
            if didCreateUser {
                Output.printErr("密码: \(options.password)")
            }
            if !shouldStartGateway {
                Output.printErr("提示: gateway 未自动启动，可执行 `clawdhome start \(options.username)`")
            }
        }
    }

    private static func runPhase(
        _ phase: InitCLIPhase,
        state: inout CLIInitState,
        username: String,
        proxy: ClawdHomeHelperProtocol,
        action: () throws -> Void
    ) throws {
        if state.cliPhases[phase.rawValue] == "done" {
            logInit("跳过阶段：\(phase.displayName)（已完成）", username: username)
            return
        }

        logInit("开始阶段：\(phase.displayName)", username: username)
        state.cliCurrentPhase = phase.rawValue
        state.cliPhases[phase.rawValue] = "running"
        state.currentStep = phase.compatStep.rawValue
        state.steps[phase.compatStep.rawValue] = "running"
        state.updatedAt = Date()
        try saveState(proxy: proxy, username: username, state: state)

        do {
            try action()
            state.cliPhases[phase.rawValue] = "done"
            state.steps[phase.compatStep.rawValue] = "done"
            state.stepErrors.removeValue(forKey: phase.compatStep.rawValue)
            state.updatedAt = Date()
            try saveState(proxy: proxy, username: username, state: state)
            logInit("阶段完成：\(phase.displayName)", username: username)
        } catch {
            state.cliPhases[phase.rawValue] = "failed"
            state.steps[phase.compatStep.rawValue] = "failed"
            state.stepErrors[phase.compatStep.rawValue] = error.localizedDescription
            state.updatedAt = Date()
            try? saveState(proxy: proxy, username: username, state: state)
            logInit("阶段失败：\(phase.displayName) - \(error.localizedDescription)", username: username)
            throw error
        }
    }

    private static func logInit(_ message: String, username: String) {
        guard !Output.jsonMode else { return }
        Output.printErr("[init][\(username)] \(message)")
    }

    private static func resolveBindingPlan(options: InitRunOptions, username: String) throws -> InitBindingPlan {
        var bindFeishu = options.bindFeishu
        var bindWeixin = options.bindWeixin

        guard options.interactiveBinding else {
            return InitBindingPlan(bindFeishu: bindFeishu, bindWeixin: bindWeixin)
        }

        guard isatty(STDIN_FILENO) == 1 else {
            throw CLIError.operationFailed("--interactive-binding 需要在交互终端中运行")
        }

        Output.printErr("")
        Output.printErr("=== IM 绑定（可选） @\(username) ===")
        if promptYesNo("是否执行飞书扫码绑定？", defaultValue: false) {
            bindFeishu = true
        }
        if promptYesNo("是否执行微信扫码绑定？", defaultValue: false) {
            bindWeixin = true
        }

        return InitBindingPlan(bindFeishu: bindFeishu, bindWeixin: bindWeixin)
    }

    private static func performChannelBindings(
        plan: InitBindingPlan,
        username: String,
        proxy: ClawdHomeHelperProtocol
    ) throws {
        logInit("开始 IM 扫码绑定", username: username)

        if plan.bindFeishu {
            logInit("开始飞书扫码绑定（请按提示扫码）", username: username)
            try runMaintenanceCommandStreaming(
                username: username,
                title: "飞书扫码绑定",
                command: ["npx", "-y", "@larksuite/openclaw-lark-tools", "install"],
                proxy: proxy
            )
            logInit("飞书扫码绑定完成", username: username)
        }

        if plan.bindWeixin {
            logInit("开始微信扫码绑定（请按提示扫码）", username: username)
            try runMaintenanceCommandStreaming(
                username: username,
                title: "微信扫码绑定",
                command: ["npx", "-y", "@tencent-weixin/openclaw-weixin-cli@latest", "install"],
                proxy: proxy
            )
            logInit("微信扫码绑定完成", username: username)
        }

        logInit("IM 扫码绑定阶段结束", username: username)
    }

    private static func runMaintenanceCommandStreaming(
        username: String,
        title: String,
        command: [String],
        proxy: ClawdHomeHelperProtocol
    ) throws {
        let commandJSONData = try JSONEncoder().encode(command)
        guard let commandJSON = String(data: commandJSONData, encoding: .utf8) else {
            throw CLIError.operationFailed("\(title)：命令序列化失败")
        }

        let (startOK, sessionID, startErr) = syncCallMaintenanceStart {
            proxy.startMaintenanceTerminalSession(
                username: username,
                commandJSON: commandJSON,
                withReply: $0
            )
        }
        guard startOK else {
            throw CLIError.operationFailed("\(title) 启动失败: \(startErr ?? "未知错误")")
        }

        defer {
            _ = syncCall2 {
                proxy.terminateMaintenanceTerminalSession(sessionID: sessionID, withReply: $0)
            }
        }

        var offset: Int64 = 0
        while true {
            let (ok, chunk, nextOffset, exited, exitCode, pollErr) = syncCallMaintenancePoll {
                proxy.pollMaintenanceTerminalSession(
                    sessionID: sessionID,
                    fromOffset: offset,
                    withReply: $0
                )
            }
            guard ok else {
                throw CLIError.operationFailed("\(title) 失败: \(pollErr ?? "会话轮询失败")")
            }

            offset = nextOffset
            if !chunk.isEmpty {
                FileHandle.standardError.write(chunk)
            }

            if exited {
                if exitCode != 0 {
                    throw CLIError.operationFailed("\(title) 失败（exit \(exitCode)）")
                }
                break
            }
        }
    }

    private static func runChatVerification(
        options: InitRunOptions,
        client: CLIHelperClient
    ) throws {
        logInit("开始 chat 验证", username: options.username)
        let args: [String] = [
            options.username,
            options.verifyChatMessage,
            "--session", options.verifyChatSession,
            "--timeout", String(Int(options.verifyChatTimeout)),
        ]
        try ChatCommand.run(args, client: client)
        logInit("chat 验证完成", username: options.username)
    }

    private static func promptYesNo(_ question: String, defaultValue: Bool) -> Bool {
        let suffix = defaultValue ? "[Y/n]" : "[y/N]"
        Output.printErr("\(question) \(suffix)")
        guard let raw = readLine(strippingNewline: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty
        else {
            return defaultValue
        }

        switch raw {
        case "y", "yes", "1", "是":
            return true
        case "n", "no", "0", "否":
            return false
        default:
            return defaultValue
        }
    }

    // MARK: - Persona staging/finalization

    private static func stagePendingPersonas(
        username: String,
        entries: [PendingPersonaEntry],
        proxy: ClawdHomeHelperProtocol
    ) throws {
        let (mkOK, mkErr) = syncCall2 {
            proxy.createDirectory(username: username, relativePath: ".openclaw/workspace", withReply: $0)
        }
        if !mkOK, let mkErr, !mkErr.isEmpty {
            throw CLIError.operationFailed("创建 pending 目录失败: \(mkErr)")
        }

        let pendingPath = ".openclaw/workspace/pending_v2_agents.json"
        let data = try JSONEncoder().encode(entries)
        let (ok, err) = syncCallWrite {
            proxy.writeFile(username: username, relativePath: pendingPath, data: data, withReply: $0)
        }
        if !ok {
            throw CLIError.operationFailed("写入 pending_v2_agents.json 失败: \(err ?? "未知错误")")
        }
    }

    private static func finalizePersonasFromPending(
        username: String,
        proxy: ClawdHomeHelperProtocol
    ) throws {
        let pendingPath = ".openclaw/workspace/pending_v2_agents.json"
        let (pendingDataOpt, pendingErr) = syncCallRead {
            proxy.readFile(username: username, relativePath: pendingPath, withReply: $0)
        }
        if let pendingErr, !pendingErr.isEmpty {
            throw CLIError.operationFailed("读取 pending_v2_agents.json 失败: \(pendingErr)")
        }
        guard let pendingData = pendingDataOpt, !pendingData.isEmpty else {
            return
        }
        let entries = (try? JSONDecoder().decode([PendingPersonaEntry].self, from: pendingData)) ?? []
        if entries.isEmpty {
            return
        }

        let (agentsJSONOpt, listErr) = syncCallOptionalString2 {
            proxy.listAgents(username: username, withReply: $0)
        }
        if let listErr, !listErr.isEmpty {
            throw CLIError.operationFailed("读取 agent 列表失败: \(listErr)")
        }
        guard let agentsJSONOpt,
              let listData = agentsJSONOpt.data(using: .utf8),
              let profiles = try? JSONDecoder().decode([CLIInitAgentProfile].self, from: listData)
        else {
            throw CLIError.operationFailed("解析 agent 列表失败")
        }

        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var unresolved: [PendingPersonaEntry] = []

        for entry in entries {
            let preferredID = entry.agentDefId
            let fallbackID = normalizeAgentID(preferredID)
            guard let profile = byID[preferredID] ?? byID[fallbackID] else {
                unresolved.append(entry)
                continue
            }

            let workspaceRel = relativeWorkspacePath(
                username: username,
                workspacePath: profile.workspacePath,
                fallbackAgentID: profile.id
            )
            let (mkOK, mkErr) = syncCall2 {
                proxy.createDirectory(username: username, relativePath: workspaceRel, withReply: $0)
            }
            if !mkOK, let mkErr, !mkErr.isEmpty {
                throw CLIError.operationFailed("创建工作区目录失败(\(profile.id)): \(mkErr)")
            }

            try writePersonaFileIfNeeded(
                username: username,
                proxy: proxy,
                workspaceRel: workspaceRel,
                fileName: "SOUL.md",
                content: entry.dna.fileSoul
            )
            try writePersonaFileIfNeeded(
                username: username,
                proxy: proxy,
                workspaceRel: workspaceRel,
                fileName: "IDENTITY.md",
                content: entry.dna.fileIdentity
            )
            try writePersonaFileIfNeeded(
                username: username,
                proxy: proxy,
                workspaceRel: workspaceRel,
                fileName: "USER.md",
                content: entry.dna.fileUser
            )
        }

        let remainedData = try JSONEncoder().encode(unresolved)
        let (ok, err) = syncCallWrite {
            proxy.writeFile(username: username, relativePath: pendingPath, data: remainedData, withReply: $0)
        }
        if !ok {
            throw CLIError.operationFailed("写回 pending_v2_agents.json 失败: \(err ?? "未知错误")")
        }
        if !unresolved.isEmpty {
            throw CLIError.operationFailed("仍有 \(unresolved.count) 个 persona 未匹配到 agent，请稍后 resume")
        }
    }

    private static func writePersonaFileIfNeeded(
        username: String,
        proxy: ClawdHomeHelperProtocol,
        workspaceRel: String,
        fileName: String,
        content: String?
    ) throws {
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let relPath = "\(workspaceRel)/\(fileName)"
        let (ok, err) = syncCallWrite {
            proxy.writeFile(
                username: username,
                relativePath: relPath,
                data: Data(content.utf8),
                withReply: $0
            )
        }
        if !ok {
            throw CLIError.operationFailed("写入 \(relPath) 失败: \(err ?? "未知错误")")
        }
    }

    private static func relativeWorkspacePath(
        username: String,
        workspacePath: String?,
        fallbackAgentID: String
    ) -> String {
        guard let workspacePath, !workspacePath.isEmpty else {
            return ".openclaw/workspace-\(fallbackAgentID)"
        }
        if workspacePath.hasPrefix("~/") {
            return String(workspacePath.dropFirst(2))
        }
        let homePrefix = "/Users/\(username)/"
        if workspacePath.hasPrefix(homePrefix) {
            return String(workspacePath.dropFirst(homePrefix.count))
        }
        return ".openclaw/workspace-\(fallbackAgentID)"
    }

    private static func normalizeAgentID(_ value: String) -> String {
        let lower = value.lowercased()
        let filtered = lower.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { return ch }
            return "-"
        }
        let collapsed = String(filtered).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Options + plan parsing

    private static func parseRunLikeOptions(_ args: [String], command: String) throws -> InitRunOptions {
        guard let username = args.first, !username.isEmpty else {
            Output.printError("用法: clawdhome init \(command) <name> [options]")
            exit(1)
        }

        var fullName = username
        var password = UUID().uuidString
        var configPath: String?
        var version = "latest"
        var startGateway = false
        var finalizePersona = true
        var interactiveBinding = false
        var bindFeishu = false
        var bindWeixin = false
        var verifyChat = false
        var verifyChatMessage = "请简短回复：初始化验证成功"
        var verifyChatSession = "default"
        var verifyChatTimeout: TimeInterval = 120
        var npmRegistry = NpmRegistryOption.defaultForInitialization.rawValue
        var proxyURL: String?
        var noProxy: String?

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--full-name" where i + 1 < args.count:
                fullName = args[i + 1]
                i += 2
            case "--password" where i + 1 < args.count:
                password = args[i + 1]
                i += 2
            case "--config" where i + 1 < args.count:
                configPath = args[i + 1]
                i += 2
            case "--version" where i + 1 < args.count:
                version = args[i + 1]
                i += 2
            case "--start-gateway":
                startGateway = true
                i += 1
            case "--skip-persona-finalize":
                finalizePersona = false
                i += 1
            case "--interactive-binding":
                interactiveBinding = true
                i += 1
            case "--bind-feishu":
                bindFeishu = true
                i += 1
            case "--bind-weixin", "--bind-wechat":
                bindWeixin = true
                i += 1
            case "--verify-chat":
                verifyChat = true
                i += 1
            case "--verify-chat-message" where i + 1 < args.count:
                verifyChat = true
                verifyChatMessage = args[i + 1]
                i += 2
            case "--verify-chat-session" where i + 1 < args.count:
                verifyChat = true
                verifyChatSession = args[i + 1]
                i += 2
            case "--verify-chat-timeout" where i + 1 < args.count:
                verifyChat = true
                guard let value = TimeInterval(args[i + 1]), value > 0 else {
                    throw CLIError.operationFailed("--verify-chat-timeout 需要大于 0 的数字")
                }
                verifyChatTimeout = value
                i += 2
            case "--npm-registry" where i + 1 < args.count:
                npmRegistry = args[i + 1]
                i += 2
            case "--proxy" where i + 1 < args.count:
                proxyURL = args[i + 1]
                i += 2
            case "--no-proxy" where i + 1 < args.count:
                noProxy = args[i + 1]
                i += 2
            default:
                throw CLIError.operationFailed("未知参数: \(args[i])")
            }
        }

        return InitRunOptions(
            username: username,
            fullName: fullName,
            password: password,
            configPath: configPath,
            openclawVersion: version,
            startGateway: startGateway,
            finalizePersona: finalizePersona,
            interactiveBinding: interactiveBinding,
            bindFeishu: bindFeishu,
            bindWeixin: bindWeixin,
            verifyChat: verifyChat,
            verifyChatMessage: verifyChatMessage,
            verifyChatSession: verifyChatSession,
            verifyChatTimeout: verifyChatTimeout,
            npmRegistry: npmRegistry,
            proxyURL: proxyURL,
            noProxy: noProxy
        )
    }

    private static func loadPlan(options: InitRunOptions, state: CLIInitState) throws -> InitPlan {
        let resolvedPath = options.configPath ?? state.cliConfigPath
        guard let resolvedPath else {
            return InitPlan.defaultPlan(displayName: options.username)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
        let dec = JSONDecoder()

        if let wrapped = try? dec.decode(InitPlanFile.self, from: data), let cfg = wrapped.config {
            return InitPlan(config: cfg, personas: wrapped.personas ?? wrapped.agentDNAs ?? [])
        }
        if let plain = try? dec.decode(ShrimpConfigV2.self, from: data) {
            return InitPlan(config: plain, personas: [])
        }

        throw CLIError.operationFailed("无法解析配置文件: \(resolvedPath)")
    }

    // MARK: - State read/write

    private static func loadState(proxy: ClawdHomeHelperProtocol, username: String) -> CLIInitState? {
        let raw = syncCallString { proxy.loadInitState(username: username, withReply: $0) }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CLIInitState.from(json: raw)
    }

    private static func saveState(proxy: ClawdHomeHelperProtocol, username: String, state: CLIInitState) throws {
        let json = state.toJSON()
        let (ok, err) = syncCall2 { proxy.saveInitState(username: username, json: json, withReply: $0) }
        if !ok {
            throw CLIError.operationFailed("保存初始化状态失败: \(err ?? "未知错误")")
        }
    }

    // MARK: - XPC sync helpers

    private static func syncCallRead(_ block: @escaping (@escaping (Data?, String?) -> Void) -> Void) -> (Data?, String?) {
        let sema = DispatchSemaphore(value: 0)
        var data: Data?
        var err: String?
        block { d, e in
            data = d
            err = e
            sema.signal()
        }
        sema.wait()
        return (data, err)
    }

    private static func syncCallWrite(_ block: @escaping (@escaping (Bool, String?) -> Void) -> Void) -> (Bool, String?) {
        let sema = DispatchSemaphore(value: 0)
        var ok = false
        var err: String?
        block { success, error in
            ok = success
            err = error
            sema.signal()
        }
        sema.wait()
        return (ok, err)
    }

    private static func syncCallOptionalString2(_ block: @escaping (@escaping (String?, String?) -> Void) -> Void) -> (String?, String?) {
        let sema = DispatchSemaphore(value: 0)
        var value: String?
        var err: String?
        block { v, e in
            value = v
            err = e
            sema.signal()
        }
        sema.wait()
        return (value, err)
    }

    private static func syncCallMaintenanceStart(
        _ block: @escaping (@escaping (Bool, String, String?) -> Void) -> Void
    ) -> (Bool, String, String?) {
        let sema = DispatchSemaphore(value: 0)
        var ok = false
        var sessionID = ""
        var err: String?
        block { success, id, error in
            ok = success
            sessionID = id
            err = error
            sema.signal()
        }
        sema.wait()
        return (ok, sessionID, err)
    }

    private static func syncCallMaintenancePoll(
        _ block: @escaping (@escaping (Bool, Data, Int64, Bool, Int32, String?) -> Void) -> Void
    ) -> (Bool, Data, Int64, Bool, Int32, String?) {
        let sema = DispatchSemaphore(value: 0)
        var ok = false
        var chunk = Data()
        var nextOffset: Int64 = 0
        var exited = false
        var exitCode: Int32 = -1
        var err: String?
        block { success, data, offset, didExit, code, error in
            ok = success
            chunk = data
            nextOffset = offset
            exited = didExit
            exitCode = code
            err = error
            sema.signal()
        }
        sema.wait()
        return (ok, chunk, nextOffset, exited, exitCode, err)
    }

    private static func iso8601String(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }
}

// MARK: - Models

private enum InitCLIPhase: String, CaseIterable {
    case createUser
    case setupWorkspace
    case repairHomebrew
    case installNode
    case setupNpmEnv
    case setNpmRegistry
    case installOpenclaw
    case applyV2Config
    case stagePendingPersona
    case startGateway
    case finalizePersona

    var compatStep: InitStepCompat {
        switch self {
        case .createUser, .setupWorkspace, .repairHomebrew,
             .installNode, .setupNpmEnv, .setNpmRegistry, .installOpenclaw:
            return .basicEnvironment
        case .applyV2Config, .stagePendingPersona, .finalizePersona:
            return .injectRole
        case .startGateway:
            return .finish
        }
    }

    var displayName: String {
        switch self {
        case .createUser:
            return "创建用户"
        case .setupWorkspace:
            return "初始化工作区"
        case .repairHomebrew:
            return "修复 Homebrew 权限"
        case .installNode:
            return "安装 Node.js"
        case .setupNpmEnv:
            return "配置 npm 环境"
        case .setNpmRegistry:
            return "设置 npm 安装源"
        case .installOpenclaw:
            return "安装 openclaw"
        case .applyV2Config:
            return "写入 V2 配置"
        case .stagePendingPersona:
            return "写入 pending persona"
        case .startGateway:
            return "启动 gateway"
        case .finalizePersona:
            return "落盘 persona 文件"
        }
    }
}

private enum InitStepCompat: String {
    case basicEnvironment
    case injectRole
    case finish
}

private struct InitRunOptions {
    let username: String
    let fullName: String
    let password: String
    let configPath: String?
    let openclawVersion: String
    let startGateway: Bool
    let finalizePersona: Bool
    let interactiveBinding: Bool
    let bindFeishu: Bool
    let bindWeixin: Bool
    let verifyChat: Bool
    let verifyChatMessage: String
    let verifyChatSession: String
    let verifyChatTimeout: TimeInterval
    let npmRegistry: String
    let proxyURL: String?
    let noProxy: String?

    var openclawVersionForState: String {
        openclawVersion.isEmpty ? "latest" : openclawVersion
    }
}

private struct InitBindingPlan {
    let bindFeishu: Bool
    let bindWeixin: Bool

    var hasAny: Bool { bindFeishu || bindWeixin }

    var channels: [String] {
        var result: [String] = []
        if bindFeishu { result.append("feishu") }
        if bindWeixin { result.append("openclaw-weixin") }
        return result
    }
}

private struct InitPlan {
    let config: ShrimpConfigV2
    let personas: [PendingPersonaEntry]

    static func defaultPlan(displayName: String) -> InitPlan {
        let config = ShrimpConfigV2(
            agents: [
                AgentDef(
                    id: "main",
                    displayName: displayName,
                    isDefault: true,
                    workspace: nil,
                    modelPrimary: nil,
                    modelFallbacks: []
                ),
            ],
            imAccounts: [],
            bindings: [],
            providers: [],
            feishuTopLevel: nil,
            sessionDmScope: nil
        )
        return InitPlan(config: config, personas: [])
    }

    func encodeConfigJSON() throws -> String {
        let data = try JSONEncoder().encode(config)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CLIError.operationFailed("配置序列化失败")
        }
        return json
    }
}

private struct InitPlanFile: Codable {
    var config: ShrimpConfigV2?
    var personas: [PendingPersonaEntry]?
    var agentDNAs: [PendingPersonaEntry]?
}

private struct PendingPersonaEntry: Codable {
    var agentDefId: String
    var dna: PendingPersonaDNA
}

private struct PendingPersonaDNA: Codable {
    var id: String?
    var name: String
    var fileSoul: String?
    var fileIdentity: String?
    var fileUser: String?
}

private struct CLIInitAgentProfile: Codable {
    var id: String
    var workspacePath: String?
}

private struct CLIInitState: Codable {
    var schemaVersion: Int = 2
    var mode: String = "onboarding"
    var active: Bool = false
    var currentStep: String?
    var steps: [String: String] = [:]
    var stepErrors: [String: String] = [:]
    var npmRegistry: String?
    var openclawVersion: String = "latest"
    var modelName: String = ""
    var channelType: String = ""
    var updatedAt: Date = Date()
    var completedAt: Date?

    // CLI 扩展字段（App 会忽略未知字段）
    var cliCurrentPhase: String?
    var cliPhases: [String: String] = [:]
    var cliConfigPath: String?

    static func from(json: String) -> CLIInitState? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CLIInitState.self, from: data)
    }

    func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

private enum InstanceExists {
    static func check(_ username: String) throws -> Bool {
        FileManager.default.fileExists(atPath: "/Users/\(username)")
    }
}
