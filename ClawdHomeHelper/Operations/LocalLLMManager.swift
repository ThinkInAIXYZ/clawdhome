// ClawdHomeHelper/Operations/LocalLLMManager.swift
// 管理 omlx LLM 服务：安装、启动、停止、模型列表、下载
// 以管理员账户运行（LaunchDaemon + UserName），不以 root 运行，Metal GPU 可用

import Foundation

struct LocalLLMManager {
    static let label      = "ai.clawdhome.omlx"
    static let port       = 18800
    static let plistPath  = "/Library/LaunchDaemons/ai.clawdhome.omlx.plist"
    static let modelDir   = "/Users/Shared/ClawdHome/models/omlx"

    // MARK: - 安装 omlx

    static func install(adminUsername: String) throws {
        helperLog("[omlx] 跳过自动安装（brew 路径已移除），admin=\(adminUsername)", level: .warn)
        throw LocalAIError.installViaBrewRemoved
    }

    // MARK: - 状态查询

    static func status() -> LocalServiceStatus {
        let printOut = try? run("/bin/launchctl", args: ["print", "system/\(label)"])
        guard printOut != nil else {
            return LocalServiceStatus(isInstalled: isOmlxInstalled(),
                                      isRunning: false, pid: -1,
                                      currentModelId: "", port: port)
        }
        let (running, pid) = parseRunning(from: printOut ?? "")
        return LocalServiceStatus(isInstalled: true, isRunning: running, pid: pid,
                                  currentModelId: "", port: port)
    }

    static func isOmlxInstalled() -> Bool { findOmlxBinary() != nil }

    static func findOmlxBinary() -> String? {
        ["/opt/homebrew/bin/omlx", "/usr/local/bin/omlx"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - 启动

    static func start(adminUsername: String) throws {
        guard let binary = findOmlxBinary() else {
            throw LocalAIError.notInstalled("omlx")
        }
        ensureModelDir()
        let plist = makePlist(binary: binary, adminUsername: adminUsername)
        let existing = try? String(contentsOfFile: plistPath, encoding: .utf8)
        let printOut = try? run("/bin/launchctl", args: ["print", "system/\(label)"])

        if printOut != nil {
            let (running, _) = parseRunning(from: printOut ?? "")
            if running { helperLog("[omlx] 已在运行，跳过"); return }
            if existing != plist {
                if (try? run("/bin/launchctl", args: ["bootout", "system/\(label)"])) == nil {
                    helperLog("[omlx] launchctl bootout system/\(label) failed before config-change bootstrap", level: .warn)
                }
                Thread.sleep(forTimeInterval: 0.3)
                try writePlist(plist)
                try run("/bin/launchctl", args: ["bootstrap", "system", plistPath])
            } else {
                if (try? run("/bin/launchctl", args: ["kickstart", "system/\(label)"])) == nil {
                    helperLog("[omlx] launchctl kickstart system/\(label) failed", level: .warn)
                }
            }
        } else {
            try writePlist(plist)
            try run("/bin/launchctl", args: ["bootstrap", "system", plistPath])
        }
        helperLog("[omlx] 启动成功 port=\(port)")
    }

    // MARK: - 停止

    static func stop() throws {
        try run("/bin/launchctl", args: ["bootout", "system/\(label)"])
        helperLog("[omlx] 已停止")
    }

    // MARK: - 模型管理

    static func listModels() -> [LocalModelInfo] {
        ensureModelDir()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: modelDir) else { return [] }
        return items.compactMap { item -> LocalModelInfo? in
            guard !item.hasPrefix(".") else { return nil }
            let fullPath = "\(modelDir)/\(item)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { return nil }
            let sizeGB = Double(directorySize(fullPath)) / 1_073_741_824.0
            let curated = curatedLLMModels.first { $0.id.hasSuffix(item) }
            let modelId = curated?.id ?? "local/\(item)"
            return LocalModelInfo(id: modelId, displayName: curated?.displayName ?? item,
                                  sizeGB: sizeGB, isDownloaded: true, isManual: curated == nil)
        }
    }

    static func deleteModel(modelId: String) throws {
        let dirName = modelId.components(separatedBy: "/").last ?? modelId
        let path = "\(modelDir)/\(dirName)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw LocalAIError.modelNotFound(modelId)
        }
        try FileManager.default.removeItem(atPath: path)
        helperLog("[omlx] 已删除模型: \(dirName)")
    }

    static func downloadModel(modelId: String, adminUsername: String) throws {
        ensureModelDir()
        let dirName = modelId.components(separatedBy: "/").last ?? modelId
        let localDir = "\(modelDir)/\(dirName)"
        helperLog("[omlx] 安装 huggingface_hub")
        try runAsAdmin(["pip3", "install", "-q", "huggingface_hub"], admin: adminUsername)
        helperLog("[omlx] 开始下载 \(modelId)")
        try runAsAdmin([
            "python3", "-c",
            "from huggingface_hub import snapshot_download; snapshot_download('\(modelId)', local_dir='\(localDir)')"
        ], admin: adminUsername)
        _ = try? run("/bin/chmod", args: ["-R", "755", localDir])
        helperLog("[omlx] 下载完成: \(modelId)")
    }

    // MARK: - 内部工具

    private static func ensureModelDir() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: modelDir) else { return }
        try? fm.createDirectory(atPath: modelDir, withIntermediateDirectories: true)
        _ = try? run("/bin/chmod", args: ["755", "/Users/Shared/ClawdHome"])
        _ = try? run("/bin/chmod", args: ["755", modelDir])
    }

    private static func runAsAdmin(_ args: [String], admin: String) throws {
        try run("/usr/bin/sudo", args: ["-u", admin, "-H", "/usr/bin/env"] + args)
    }

    private static func writePlist(_ content: String) throws {
        try content.write(toFile: plistPath, atomically: true, encoding: .utf8)
        try run("/usr/sbin/chown", args: ["root:wheel", plistPath])
        try run("/bin/chmod", args: ["644", plistPath])
    }

    private static func makePlist(binary: String, adminUsername: String) -> String {
        let brewPrefix = binary.contains("/opt/homebrew") ? "/opt/homebrew/bin" : "/usr/local/bin"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>UserName</key>
            <string>\(adminUsername)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>serve</string>
                <string>--model-dir</string>
                <string>\(modelDir)</string>
                <string>--port</string>
                <string>\(port)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>\(brewPrefix):/usr/local/bin:/usr/bin:/bin</string>
                <key>HOME</key>
                <string>/Users/\(adminUsername)</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>/tmp/clawdhome-omlx.log</string>
            <key>StandardOutPath</key>
            <string>/tmp/clawdhome-omlx.log</string>
        </dict>
        </plist>
        """
    }

    private static func parseRunning(from output: String) -> (Bool, Int32) {
        for line in output.components(separatedBy: "\n") where line.contains("pid = ") {
            if let pidStr = line.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces),
               let pid = Int32(pidStr), pid > 0 { return (true, pid) }
        }
        return (false, -1)
    }

    private static func directorySize(_ path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

enum LocalAIError: LocalizedError {
    case notInstalled(String)
    case modelNotFound(String)
    case adminNotAvailable
    case installViaBrewRemoved

    var errorDescription: String? {
        switch self {
        case .notInstalled(let tool): return "\(tool) 未安装，请先点击「安装」"
        case .modelNotFound(let id):  return "模型不存在：\(id)"
        case .adminNotAvailable:      return "无法获取管理员账户，请确认正在登录状态"
        case .installViaBrewRemoved:  return "已移除 brew 自动安装，请先手动安装 omlx 后再启动"
        }
    }
}
