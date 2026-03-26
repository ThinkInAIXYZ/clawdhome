// Shared/HelperProtocol.swift
// App 与 Helper 双方共用的 XPC 接口定义
// 注意：XPC 协议必须继承 NSObjectProtocol，方法参数只能使用 ObjC 兼容类型

import Foundation

/// Helper 对外暴露的操作接口（ClawdHome.app 调用）
@objc protocol ClawdHomeHelperProtocol: NSObjectProtocol {
    /// 获取 Helper 版本号，用于连通性验证
    func getVersion(withReply reply: @escaping (String) -> Void)

    /// 在系统创建新的 macOS 标准用户账户
    func createUser(
        username: String,
        fullName: String,
        password: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 删除指定 macOS 用户（可选择保留 home 目录）
    func deleteUser(
        username: String,
        keepHome: Bool,
        adminUser: String,
        adminPassword: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 删除前预清理：停止 gateway、从所有系统群组中移除用户
    /// 必须在 sysadminctl -deleteUser **之前**调用（需读取用户 GeneratedUID）
    func prepareDeleteUser(
        username: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 删除后清理：移除 Helper 侧状态文件
    /// 在 sysadminctl -deleteUser **之后**调用
    func cleanupDeletedUser(
        username: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 以指定用户身份启动 openclaw-gateway（通过 launchctl）
    func startGateway(
        username: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 停止指定用户的 openclaw-gateway
    func stopGateway(
        username: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 原子重启指定用户的 gateway（launchctl kickstart -k，无竞争窗口）
    /// 仅在 service 已注册时有效；未注册时回退到 startGateway
    func restartGateway(
        username: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 查询指定用户的 gateway 运行状态，返回 (isRunning, pid)
    func getGatewayStatus(
        username: String,
        withReply reply: @escaping (Bool, Int32) -> Void
    )

    /// 写入指定用户的 openclaw 配置项（~/.openclaw/）
    func setConfig(
        username: String,
        key: String,
        value: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 为指定用户安装或升级 openclaw（npm install -g）
    func installOpenclaw(
        username: String,
        version: String?,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 查询指定用户已安装的 openclaw 版本（未安装返回空字符串）
    func getOpenclawVersion(
        username: String,
        withReply reply: @escaping (String) -> Void
    )

    /// 为指定用户安装 Node.js（直接下载）
    func installNode(
        username: String,
        nodeDistURL: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// Node.js 是否已安装就绪（用于控制 npm 相关操作开关）
    func isNodeInstalled(withReply reply: @escaping (Bool) -> Void)

    /// 获取 Xcode/CLT 环境状态（JSON 编码的 XcodeEnvStatus）
    func getXcodeEnvStatus(withReply reply: @escaping (String) -> Void)

    /// 触发安装 Xcode Command Line Tools（等价 xcode-select --install）
    func installXcodeCommandLineTools(withReply reply: @escaping (Bool, String?) -> Void)

    /// 接受 Xcode 许可（等价 xcodebuild -license accept）
    func acceptXcodeLicense(withReply reply: @escaping (Bool, String?) -> Void)

    /// 为指定用户初始化 npm 全局目录（~/.npm-global）并配置 shell 环境
    func setupNpmEnv(
        username: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 修复普通用户 Homebrew 安装权限（安装到 ~/.brew，并写入环境变量）
    func repairHomebrewPermission(
        username: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 设置指定用户 npm 安装源（写入用户级 ~/.npmrc）
    func setNpmRegistry(
        username: String,
        registry: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 读取指定用户 npm 安装源（优先用户级配置）
    func getNpmRegistry(
        username: String,
        withReply reply: @escaping (String) -> Void
    )

    /// 返回指定用户的 gateway 访问 URL（如 "http://localhost:18501"）
    func getGatewayURL(
        username: String,
        withReply reply: @escaping (String) -> Void
    )

    /// 取消指定用户的初始化命令（brew/npm install）
    func cancelInit(username: String, withReply reply: @escaping (Bool) -> Void)

    /// 重置指定用户的 openclaw 运行环境
    /// 删除 ~/.npm-global 和 ~/.openclaw，不删除家目录其他内容
    func resetUserEnv(
        username: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 备份指定用户的 ~/.openclaw 数据到目标路径（tar.gz）
    /// destinationPath：目标文件完整路径（由 app 通过 NSSavePanel 获取）
    func backupUser(
        username: String,
        destinationPath: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 从备份包恢复指定用户的 ~/.openclaw（解压 tar.gz 并修正权限）
    /// sourcePath：备份文件完整路径（由 app 通过 NSOpenPanel 获取）
    func restoreUser(
        username: String,
        sourcePath: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 扫描可克隆的新虾数据项（返回 CloneScanResult JSON）
    func scanCloneClaw(
        username: String,
        withReply reply: @escaping (String, String?) -> Void
    )

    /// 执行克隆新虾（requestJSON = CloneClawRequest），返回 CloneClawResult JSON
    func cloneClaw(
        requestJSON: String,
        withReply reply: @escaping (Bool, String, String?) -> Void
    )

    /// 保存指定用户的向导初始化进度（JSON 字符串）到 /var/lib/clawdhome/<username>-init.json
    func saveInitState(
        username: String,
        json: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 读取指定用户的向导初始化进度，文件不存在时返回空字符串
    func loadInitState(
        username: String,
        withReply reply: @escaping (String) -> Void
    )

    /// 获取仪表盘快照（JSON 编码的 DashboardSnapshot）
    /// Helper 内部缓存，调用无阻塞
    func getDashboardSnapshot(withReply reply: @escaping (String) -> Void)

    /// 获取当前连接列表（JSON 编码的 [ConnectionInfo]，无连接时返回 nil）
    func getConnections(withReply reply: @escaping (String?) -> Void)

    // 网络策略读写
    func getShrimpNetworkPolicy(username: String, withReply reply: @escaping (String?) -> Void)
    func setShrimpNetworkPolicy(username: String, policyJSON: String, withReply reply: @escaping (Bool, String?) -> Void)
    func getGlobalNetworkConfig(withReply reply: @escaping (String?) -> Void)
    func setGlobalNetworkConfig(configJSON: String, withReply reply: @escaping (Bool, String?) -> Void)
    // PF 开关（Phase 3 完整实现，当前仅持久化状态）
    func enableNetworkPF(withReply reply: @escaping (Bool, String?) -> Void)
    func disableNetworkPF(withReply reply: @escaping (Bool, String?) -> Void)

    /// 读取指定用户的 openclaw 配置项（key 为 dot-path，如 agents.defaults.model.primary）
    /// 未设置时返回空字符串
    func getConfig(
        username: String,
        key: String,
        withReply reply: @escaping (String) -> Void
    )

    /// 直接读取 ~/.openclaw/openclaw.json 原始内容（不启动 CLI，毫秒级）
    /// 返回 JSON 字符串，文件不存在或读取失败时返回 "{}"
    func getConfigJSON(
        username: String,
        withReply reply: @escaping (String) -> Void
    )

    /// 直接写入 ~/.openclaw/openclaw.json 指定 dot-path（不启动 CLI，毫秒级）
    /// path：dot-path，如 "agents.defaults.model.primary"
    /// valueJSON：JSON 编码的值字符串，如 "\"claude-opus-4\"" 或 "true" 或"[\"a\",\"b\"]"
    func setConfigDirect(
        username: String,
        path: String,
        valueJSON: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )


    /// 以指定用户身份运行 openclaw models 子命令
    /// argsJSON：JSON 编码的 [String]，如 ["list","--all","--json"]
    /// 返回 (success, output)
    func runModelCommand(
        username: String,
        argsJSON: String,
        withReply reply: @escaping (Bool, String) -> Void
    )

    /// 对指定用户执行体检（环境隔离检查 + 应用安全审计）
    /// fix=true 时自动修复可修复项（目前为文件权限类问题）
    /// 返回 (success, json) — json 为 JSON 编码的 HealthCheckResult
    func runHealthCheck(
        username: String,
        fix: Bool,
        withReply reply: @escaping (Bool, String) -> Void
    )

    /// 注销指定用户的登录会话（停止 gateway + launchctl bootout user/<uid>）
    /// 不删除任何数据，相当于"退出登录"
    func logoutUser(
        username: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 设置 Helper 开机是否自动启动所有被管理用户的 Gateway（默认启用）
    func setGatewayAutostart(
        enabled: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 读取 Gateway 开机自启状态（true = 启用）
    func getGatewayAutostart(withReply reply: @escaping (Bool) -> Void)

    /// 设置指定用户的开机自启开关（false = 跳过该用户的自启，默认 true）
    func setUserAutostart(
        username: String,
        enabled: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 读取指定用户的开机自启状态（true = 启用）
    func getUserAutostart(
        username: String,
        withReply reply: @escaping (Bool) -> Void
    )

    // MARK: - 文件管理

    /// 列出指定用户 home 目录下 relativePath 的内容
    /// 返回 JSON 编码的 [FileEntry]，出错时返回 nil + 错误信息
    func listDirectory(
        username: String,
        relativePath: String,
        showHidden: Bool,
        withReply reply: @escaping (String?, String?) -> Void
    )

    /// 读取文件内容（限 10MB）
    func readFile(
        username: String,
        relativePath: String,
        withReply reply: @escaping (Data?, String?) -> Void
    )

    /// 读取文件尾部内容（用于大日志文件，按字节截断）
    /// maxBytes: 读取上限，范围由 Helper 侧裁剪
    func readFileTail(
        username: String,
        relativePath: String,
        maxBytes: Int,
        withReply reply: @escaping (Data?, String?) -> Void
    )

    /// 写文件（覆盖）并纠正所有权
    func writeFile(
        username: String,
        relativePath: String,
        data: Data,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 删除文件或目录
    func deleteItem(
        username: String,
        relativePath: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 新建目录并纠正所有权
    func createDirectory(
        username: String,
        relativePath: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 重命名文件或目录（同目录内，仅改名）
    func renameItem(
        username: String,
        relativePath: String,
        newName: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 解压压缩包到同目录（支持 .zip / .tar.gz / .tgz / .tar.bz2 / .tar.xz）
    func extractArchive(
        username: String,
        relativePath: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 在用户的 memory SQLite 数据库里做全文搜索
    /// 返回 JSON 编码的 [MemoryChunkResult]，出错时返回 nil + 错误信息
    func searchMemory(
        username: String,
        query: String,
        limit: Int,
        withReply reply: @escaping (String?, String?) -> Void
    )

    // MARK: - Secrets 同步（外部 Secrets Management）

    /// 将 secrets 和 auth-profiles 同步到指定虾
    /// secretsJSON：{ "provider:accountName": "api-key", ... }
    /// authProfilesJSON：openclaw auth-profiles.json 内容（keyRef 格式）
    func syncSecrets(
        username: String,
        secretsJSON: String,
        authProfilesJSON: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 通知指定虾的 openclaw 热加载 secrets（openclaw secrets reload）
    func reloadSecrets(
        username: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 修改指定用户的 macOS 账户密码（dscl -passwd，需要 root）
    func changeUserPassword(
        username: String,
        newPassword: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    // MARK: - 屏幕共享

    /// 查询系统屏幕共享（VNC）守护进程是否正在运行
    func isScreenSharingEnabled(withReply reply: @escaping (Bool) -> Void)

    /// 启用并启动系统屏幕共享守护进程（com.apple.screensharing）
    /// 已启用时幂等返回 true
    func enableScreenSharing(withReply reply: @escaping (Bool, String?) -> Void)

    /// 以指定用户身份运行 openclaw pairing 子命令
    /// argsJSON：JSON 编码的 [String]，如 ["list","telegram","--json"]
    /// 返回 (success, output)
    func runPairingCommand(
        username: String,
        argsJSON: String,
        withReply reply: @escaping (Bool, String) -> Void
    )

    /// 以指定用户身份运行飞书通道独立配置命令
    /// 当前固定：`npx -y @larksuite/openclaw-lark-tools install`
    /// argsJSON：JSON 编码的 [String]（当前 install-only 流程中会被忽略）
    /// 返回 (success, output)
    func runFeishuOnboardCommand(
        username: String,
        argsJSON: String,
        withReply reply: @escaping (Bool, String) -> Void
    )

    /// 启动通用维护终端会话（Helper 侧 PTY），返回会话 ID
    /// commandJSON: JSON 编码的 [String]，如 ["npx","-y","@larksuite/openclaw-lark-tools","install"]
    func startMaintenanceTerminalSession(
        username: String,
        commandJSON: String,
        withReply reply: @escaping (Bool, String, String?) -> Void
    )

    /// 轮询通用维护终端会话输出
    /// fromOffset: 已读取字节偏移；返回 nextOffset（新的总长度）
    func pollMaintenanceTerminalSession(
        sessionID: String,
        fromOffset: Int64,
        withReply reply: @escaping (Bool, String, Int64, Bool, Int32, String?) -> Void
    )

    /// 向通用维护终端会话写入输入数据（Base64 编码的原始字节）
    func sendMaintenanceTerminalSessionInput(
        sessionID: String,
        inputBase64: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 调整通用维护终端会话的终端尺寸（cols/rows）
    func resizeMaintenanceTerminalSession(
        sessionID: String,
        cols: Int32,
        rows: Int32,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 终止并清理通用维护终端会话
    func terminateMaintenanceTerminalSession(
        sessionID: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 通用：以指定用户身份运行 openclaw 任意子命令
    /// argsJSON：完整参数 JSON，如 ["channels","add","--channel","telegram","--token","xxx"]
    /// 返回 (success, output) — Helper 以 root 身份运行，无需用户输入密码
    func runOpenclawCommand(
        username: String,
        argsJSON: String,
        withReply reply: @escaping (Bool, String) -> Void
    )

    // MARK: - 本地 AI 服务（omlx LLM）

    /// 安装 omlx（brew tap + brew install），长时间运行
    func installOmlx(withReply reply: @escaping (Bool, String?) -> Void)

    /// 查询 omlx 服务状态（JSON 编码的 LocalServiceStatus）
    func getLocalLLMStatus(withReply reply: @escaping (String) -> Void)

    /// 列出已下载本地模型（JSON 编码的 [LocalModelInfo]）
    func listLocalModels(withReply reply: @escaping (String) -> Void)

    /// 启动 omlx LaunchDaemon
    func startLocalLLM(withReply reply: @escaping (Bool, String?) -> Void)

    /// 停止 omlx LaunchDaemon
    func stopLocalLLM(withReply reply: @escaping (Bool, String?) -> Void)

    /// 下载模型（huggingface_hub），modelId = HuggingFace repo id（如 "mlx-community/Qwen2.5-7B-Instruct-4bit"）
    func downloadLocalModel(_ modelId: String, withReply reply: @escaping (Bool, String?) -> Void)

    /// 删除已下载模型
    func deleteLocalModel(_ modelId: String, withReply reply: @escaping (Bool, String?) -> Void)

    // MARK: - 进程管理

    /// 列出指定用户名下的所有进程（JSON 编码的 [ProcessEntry]）
    func getProcessList(
        username: String,
        withReply reply: @escaping (String) -> Void
    )

    /// 列出指定用户名下的进程快照（JSON 编码的 ProcessListSnapshot）
    /// 包含基础进程数据 + 端口扫描是否仍在进行中
    func getProcessListSnapshot(
        username: String,
        withReply reply: @escaping (String) -> Void
    )

    /// 查询指定 PID 的进程详情（JSON 编码的 ProcessDetail；未找到返回 "{}"）
    func getProcessDetail(
        pid: Int32,
        withReply reply: @escaping (String) -> Void
    )

    /// 向指定 PID 发送信号（Helper 以 root 运行）
    /// signal: 15 = SIGTERM，9 = SIGKILL
    func killProcess(
        pid: Int32,
        signal: Int32,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 读取 /var/log/clawdhome/ 下的系统审计日志（限 2MB）
    /// name: "gateway"
    func readSystemLog(
        name: String,
        withReply reply: @escaping (Data?, String?) -> Void
    )

    // MARK: - Helper 日志设置

    /// 设置 Helper 是否输出 DEBUG 级别日志（持久化到 /var/lib/clawdhome）
    func setHelperDebugLogging(
        enabled: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 读取 Helper DEBUG 日志开关
    func getHelperDebugLogging(withReply reply: @escaping (Bool) -> Void)

    // MARK: - 角色定义 Git 管理

    /// 初始化 workspace git repo（幂等）
    /// 实现：mkdir -p ~/.openclaw/workspace → git init → git config user.name/email
    func initPersonaGitRepo(
        username: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 提交单个角色文件（保存后触发，每次新建 commit）
    /// message 格式：「更新 <filename> — <ISO8601>」
    /// 前置条件：调用方须先确认 writeFile 已成功
    func commitPersonaFile(
        username: String,
        filename: String,
        message: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// 获取某文件的 git log（返回 JSON 编码的 [PersonaCommit]，仅该文件的提交历史）
    func getPersonaFileHistory(
        username: String,
        filename: String,
        withReply reply: @escaping (String?, String?) -> Void
    )

    /// 获取某 commit 相对于其父 commit 的 diff（unified diff 字符串）
    /// 初始 commit（无父）使用 git show <hash> -- <filename>
    func getPersonaFileDiff(
        username: String,
        filename: String,
        commitHash: String,
        withReply reply: @escaping (String?, String?) -> Void
    )

    /// 将单文件恢复到指定 commit 的内容，并产生新 commit
    /// 若当前内容已与目标一致（nothing to commit），视为成功
    func restorePersonaFileToCommit(
        username: String,
        filename: String,
        commitHash: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )
}

struct XcodeEnvStatus: Codable, Sendable {
    var commandLineToolsInstalled: Bool
    var clangAvailable: Bool
    var licenseAccepted: Bool
    var detail: String

    var isHealthy: Bool {
        commandLineToolsInstalled && clangAvailable && licenseAccepted
    }
}

/// XPC Mach Service 名称（App 与 Helper 均引用此常量）
let kHelperMachServiceName = "ai.clawdhome.mac.helper"

enum PairingOutputParser {
    private static let ansiPattern = "\u{001B}\\[[0-9;?]*[ -/]*[@-~]"

    static func extractQRCodeBlock(from output: String) -> String? {
        let plain = stripANSI(output)
        let lines = plain.components(separatedBy: .newlines)

        var current: [String] = []
        var best: [String] = []

        for line in lines {
            if isQRCodeLike(line) {
                current.append(line)
                if current.count > best.count {
                    best = current
                }
            } else {
                current.removeAll(keepingCapacity: true)
            }
        }

        guard best.count >= 4 else { return nil }
        return best.joined(separator: "\n")
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: ansiPattern,
            with: "",
            options: .regularExpression
        )
    }

    private static func isQRCodeLike(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let qrChars = CharacterSet(charactersIn: "█▀▄▌▐▖▗▘▙▚▛▜▝▞▟▔▁▂▃▄▅▆▇▓▒░")
        return trimmed.unicodeScalars.contains(where: { qrChars.contains($0) })
    }
}
