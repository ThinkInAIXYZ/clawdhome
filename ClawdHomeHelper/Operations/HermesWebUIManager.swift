// ClawdHomeHelper/Operations/HermesWebUIManager.swift
// 负责 hermes-webui 伴生前端服务的下载、依赖配置、端口分配与 LaunchDaemon 生命周期管理
//
// 伴生服务以对应 Shrimp 用户身份运行，通过 LaunchDaemon 守护，名字为：
// ai.clawdhome.hermes-webui.<user>.<profileID>

import Foundation

struct HermesWebUIManager {
    private static let webuiLabel = "ai.clawdhome.hermes-webui"
    private static let repositoryURL = "https://github.com/nesquena/hermes-webui.git"

    // MARK: - 路径与 Label 契约

    /// 计算 launchd label
    static func daemonLabel(username: String) -> String {
        "\(webuiLabel).\(username)"
    }

    /// WebUI 的专属安装目录：~/.clawdhome/tools/hermes-webui
    static func installDir(for username: String) -> String {
        "\(HermesInstaller.clawdhomeDir(for: username))/tools/hermes-webui"
    }

    /// launchd plist 路径
    static func launchDaemonPath(username: String) -> String {
        "/Library/LaunchDaemons/\(daemonLabel(username: username)).plist"
    }

    /// 会话状态文件路径，用于持久化分配的端口：~/.hermes/webui_session.json
    static func webuiSessionPath(username: String) -> String {
        let base = HermesInstaller.hermesHome(for: username)
        return "\(base)/webui_session.json"
    }

    private static func appendToLogFile(url: URL, message: String) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
            var attrs = [FileAttributeKey: Any]()
            attrs[.posixPermissions] = 0o666
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }
        if let fh = FileHandle(forWritingAtPath: url.path) {
            defer { fh.closeFile() }
            fh.seekToEndOfFile()
            fh.write(Data(message.utf8))
        }
    }

    // MARK: - 安装与升级

    /// 为指定用户静默克隆并安装 hermes-webui（支持进度日志）
    static func installWebUI(username: String, version: String?, logURL: URL? = nil) throws -> String {
        if let logURL {
            appendToLogFile(url: logURL, message: "========================================\n")
            appendToLogFile(url: logURL, message: "🚀 开始为用户 @\(username) 配置现代 Web 对话大厅...\n")
            appendToLogFile(url: logURL, message: "1. 正在检索系统 Python 环境...\n")
        }

        // 1. 确保 Python 前置环境就绪
        let pythonBin = try HermesInstaller.findPython(for: username)
        
        let toolsRoot = "\(HermesInstaller.clawdhomeDir(for: username))/tools"
        if !FileManager.default.fileExists(atPath: toolsRoot) {
            try FileManager.default.createDirectory(atPath: toolsRoot, withIntermediateDirectories: true, attributes: nil)
            _ = try? FilePermissionHelper.chown(toolsRoot, owner: username)
        }

        let targetDir = installDir(for: username)
        var output = ""

        if !FileManager.default.fileExists(atPath: "\(targetDir)/server.py") {
            if let logURL {
                appendToLogFile(url: logURL, message: "2. 正在克隆 WebUI 依赖仓库 (nesquena/hermes-webui)...这可能需要几秒钟...\n")
            }
            helperLog("[HermesWebUI] 正在为用户 @\(username) 克隆 WebUI 仓库...")
            // 2. clone 仓库
            let cloneArgs = ["-u", username, "-H", "env", "-i"]
                + HermesInstaller.sudoRuntimeArgs(for: username)
                + ["/usr/bin/git", "clone", repositoryURL, targetDir]
            
            if let logURL {
                output += try runLogging("/usr/bin/sudo", args: cloneArgs, logURL: logURL)
            } else {
                output += try run("/usr/bin/sudo", args: cloneArgs)
            }
            _ = try? FilePermissionHelper.chownRecursive(targetDir, owner: username)
        } else {
            if let logURL {
                appendToLogFile(url: logURL, message: "2. WebUI 依赖仓库已存在，跳过克隆。\n")
            }
            helperLog("[HermesWebUI] WebUI 仓库已存在，跳过克隆 @\(username)")
            output += "WebUI repository already exists.\n"
        }

        // 3. 执行 bootstrap 建立虚拟环境和安装依赖
        let bootstrapPy = "\(targetDir)/bootstrap.py"
        if FileManager.default.fileExists(atPath: bootstrapPy) {
            if let logURL {
                appendToLogFile(url: logURL, message: "3. 正在运行 bootstrap 预热依赖环境，创建专属隔离 Python 虚拟环境并安装 Python 第三方包...\n这需要拉取底层模块，可能耗时稍长，请耐心等候...\n")
            }
            helperLog("[HermesWebUI] 正在运行 bootstrap 预热依赖环境 @\(username)...")
            let bootstrapArgs = ["-u", username, "-H", "env", "-i"]
                + HermesInstaller.sudoRuntimeArgs(for: username)
                + [pythonBin, bootstrapPy]
            
            if let logURL {
                output += try runLogging("/usr/bin/sudo", args: bootstrapArgs, logURL: logURL)
            } else {
                output += try run("/usr/bin/sudo", args: bootstrapArgs)
            }
            _ = try? FilePermissionHelper.chownRecursive(targetDir, owner: username)
        } else {
            let err = NSError(domain: "HermesWebUI", code: 404, userInfo: [NSLocalizedDescriptionKey: "未能在克隆的目标目录中找到 bootstrap.py"])
            throw err
        }

        if let logURL {
            appendToLogFile(url: logURL, message: "🎉 恭喜！现代 Web 对话大厅配置成功完成！\n========================================\n")
        }
        helperLog("[HermesWebUI] 安装/升级完成 @\(username)")
        return output
    }

    /// 查询已安装的版本
    static func installedVersion(username: String) -> String {
        let serverPy = "\(installDir(for: username))/server.py"
        if FileManager.default.fileExists(atPath: serverPy) {
            return "0.1.0-community"
        }
        return ""
    }

    // MARK: - 端口分配

    /// 检查本地端口是否可用
    private static func isPortAvailable(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        var opt: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// 从 webui_session.json 读取或动态分配一个唯一的本地端口
    static func getOrAllocatePort(username: String, uid: Int) -> Int {
        let sessionPath = webuiSessionPath(username: username)
        
        // 确保根目录存在
        let baseDir = (sessionPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: baseDir) {
            try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true, attributes: nil)
            _ = try? FilePermissionHelper.chown(baseDir, owner: username)
        }

        if let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let savedPort = json["port"] as? Int,
           isPortAvailable(savedPort) {
            return savedPort
        }

        // 端口哈希规则：对于同一 Shrimp 实例基于 UID 分配相对稳定的端口
        let candidateBase = 19000 + (uid % 300) * 10
        var allocatedPort = candidateBase

        for offset in 0..<100 {
            let port = candidateBase + offset
            if port >= 19000 && port <= 22000 && isPortAvailable(port) {
                allocatedPort = port
                break
            }
        }

        // 兜底：首选区段被占满时，顺序扫描可用段
        if !isPortAvailable(allocatedPort) {
            for port in 19000...22000 {
                if isPortAvailable(port) {
                    allocatedPort = port
                    break
                }
            }
        }

        // 写入 session 并更正权限
        let sessionObj: [String: Any] = ["port": allocatedPort]
        if let sessionData = try? JSONSerialization.data(withJSONObject: sessionObj, options: []),
           let sessionStr = String(data: sessionData, encoding: .utf8) {
            do {
                try sessionStr.write(toFile: sessionPath, atomically: true, encoding: .utf8)
                _ = try? FilePermissionHelper.chown(sessionPath, owner: username)
            } catch {
                helperLog("[HermesWebUI] 写入端口 Session 失败: \(error.localizedDescription)", level: .error)
            }
        }

        return allocatedPort
    }

    // MARK: - 启停管理

    /// 启动伴生 WebUI 服务（幂等）
    static func startWebUI(username: String, uid: Int) throws {
        let label = daemonLabel(username: username)
        let plistPath = launchDaemonPath(username: username)

        helperLog("[HermesWebUI] START: uid=\(uid) @\(username)")

        // 1. 确保安装存在
        let targetDir = installDir(for: username)
        guard FileManager.default.fileExists(atPath: "\(targetDir)/server.py") else {
            let err = NSError(domain: "HermesWebUI", code: 404, userInfo: [NSLocalizedDescriptionKey: "尚未配置 WebUI，请先安装。"])
            throw err
        }

        // 2. 分配端口
        let port = getOrAllocatePort(username: username, uid: uid)
        helperLog("[HermesWebUI] 分配端口: \(port) @\(username)")

        // 3. 构造并写入 PLIST
        let newPlist = makePlist(username: username, targetDir: targetDir, port: port)

        // 4. 确保日志目录存在
        let baseHome = HermesInstaller.hermesHome(for: username)
        let logsDir = "\(baseHome)/logs"
        if !FileManager.default.fileExists(atPath: logsDir) {
            try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true, attributes: nil)
            _ = try? FilePermissionHelper.chown(logsDir, owner: username)
        }

        // 5. 注册并引导守护进程
        let isRegistered = (try? run("/bin/launchctl", args: ["print", "system/\(label)"])) != nil
        if isRegistered {
            let existingPlist = (try? String(contentsOfFile: plistPath, encoding: .utf8)) ?? ""
            if existingPlist == newPlist {
                helperLog("[HermesWebUI] 已注册且配置无变动，执行 kickstart @\(username)")
                _ = try? run("/bin/launchctl", args: ["kickstart", "-k", "system/\(label)"])
            } else {
                helperLog("[HermesWebUI] 配置发生变更，重置引导 @\(username)")
                _ = try? run("/bin/launchctl", args: ["bootout", "system/\(label)"])
                Thread.sleep(forTimeInterval: 0.3)
                try writePlist(newPlist, to: plistPath)
                try bootstrapSystem(label: label, plistPath: plistPath)
            }
        } else {
            helperLog("[HermesWebUI] 首次启动注册，进行 bootstrap @\(username)")
            try writePlist(newPlist, to: plistPath)
            try bootstrapSystem(label: label, plistPath: plistPath)
        }

        helperLog("[HermesWebUI] START_OK: label=\(label) port=\(port)")
    }

    /// 停止伴生 WebUI 服务
    static func stopWebUI(username: String, uid: Int) throws {
        let label = daemonLabel(username: username)
        helperLog("[HermesWebUI] STOP: label=\(label) @\(username)")
        
        do {
            try run("/bin/launchctl", args: ["bootout", "system/\(label)"])
        } catch {
            if !isIgnorableLaunchctlBootoutError(error) {
                helperLog("[HermesWebUI] bootout 返回异常：\(error.localizedDescription)", level: .warn)
            }
        }

        // 强行清理可能残留的伴生 Python 进程
        forceKillWebUIProcesses(username: username, port: getOrAllocatePort(username: username, uid: uid))
    }

    /// 状态查询
    /// Returns: (isRunning, pid, port)
    static func status(username: String) -> (running: Bool, pid: Int32, port: Int) {
        let label = daemonLabel(username: username)
        let sessionPath = webuiSessionPath(username: username)
        
        var savedPort = 0
        if let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let portVal = json["port"] as? Int {
            savedPort = portVal
        }

        guard let output = try? run("/bin/launchctl", args: ["print", "system/\(label)"]) else {
            return (false, -1, savedPort)
        }

        for line in output.components(separatedBy: "\n") where line.contains("pid = ") {
            if let pidStr = line.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces),
               let pid = Int32(pidStr), pid > 0 {
                return (true, pid, savedPort)
            }
        }

        if output.contains("state = running") {
            return (true, -1, savedPort)
        }

        return (false, -1, savedPort)
    }

    // MARK: - 内部私有辅助

    private static func isIgnorableLaunchctlBootoutError(_ error: Error) -> Bool {
        guard case let ShellError.nonZeroExit(_, status, _) = error else { return false }
        return status == 3 || status == 36 || status == 113
    }

    private static func makePlist(username: String, targetDir: String, port: Int) -> String {
        let label = daemonLabel(username: username)
        let home = "/Users/\(username)"
        let baseHome = HermesInstaller.hermesHome(for: username)
        let logPath = "\(baseHome)/logs/webui.log"
        let path = HermesInstaller.buildPath(for: username)

        // 优先使用系统克隆时找出来的 Python3，剩下的虚拟环境和依赖加载由 bootstrap.py 自身完成
        let pythonBin = (try? HermesInstaller.findPython(for: username)) ?? "/usr/bin/python3"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>UserName</key>
            <string>\(username)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(pythonBin)</string>
                <string>bootstrap.py</string>
                <string>--foreground</string>
            </array>
            <key>WorkingDirectory</key>
            <string>\(targetDir)</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>HOME</key>
                <string>\(home)</string>
                <key>USER</key>
                <string>\(username)</string>
                <key>PATH</key>
                <string>\(path)</string>
                <key>HERMES_HOME</key>
                <string>\(baseHome)</string>
                <key>HERMES_WEBUI_PORT</key>
                <string>\(port)</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    private static func writePlist(_ content: String, to path: String) throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        try FilePermissionHelper.setRootPlistPermissions(path)
    }

    private static func bootstrapSystem(label: String, plistPath: String) throws {
        for attempt in 1...3 {
            do {
                try run("/bin/launchctl", args: ["bootstrap", "system", plistPath])
                return
            } catch {
                if attempt == 3 { throw error }
                _ = try? run("/bin/launchctl", args: ["bootout", "system/\(label)"])
                Thread.sleep(forTimeInterval: 0.5 * Double(attempt))
            }
        }
    }

    /// 清理残留的伴生 Python 进程
    private static func forceKillWebUIProcesses(username: String, port: Int) {
        guard let output = try? run("/bin/ps", args: ["-axo", "pid=,user=,command="]) else { return }
        let pids = output.split(separator: "\n").compactMap { rawLine -> Int32? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3 else { return nil }
            let userField = String(fields[1])
            let commandField = String(fields[2])
            guard userField == username else { return nil }
            // 匹配 python 和 hermes-webui 关键字
            guard commandField.contains("python"), commandField.contains("server.py") else { return nil }
            return Int32(fields[0])
        }

        for pid in pids {
            helperLog("[HermesWebUI] 强制杀死残留 WebUI 进程 pid=\(pid)", level: .warn)
            _ = try? run("/bin/kill", args: ["-TERM", "\(pid)"])
        }
    }
}
