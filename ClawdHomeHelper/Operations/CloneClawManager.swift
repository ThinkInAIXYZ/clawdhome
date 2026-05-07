import Foundation

enum CloneClawManagerError: LocalizedError {
    case userNotFound(String)
    case targetUserExists(String)
    case invalidUsername(String)
    case noItemsSelected
    case selectedItemNotFound(String)
    case selectedItemDisabled(String)
    case sourceItemMissing(String)
    case ownershipFixFailed(String, String)
    case invalidRequestJSON
    case invalidConfigFormat
    case cloneCancelled(String)
    case scanEncodeFailed
    case resultEncodeFailed

    var errorDescription: String? {
        switch self {
        case .userNotFound(let username): return "用户不存在：\(username)"
        case .targetUserExists(let username): return "目标用户名已存在：\(username)"
        case .invalidUsername(let username): return "用户名不合法：\(username)"
        case .noItemsSelected: return "至少选择一项可克隆数据"
        case .selectedItemNotFound(let itemID): return "未知克隆项：\(itemID)"
        case .selectedItemDisabled(let itemID): return "克隆项不可用：\(itemID)"
        case .sourceItemMissing(let path): return "源数据缺失：\(path)"
        case .ownershipFixFailed(let path, let detail): return "权限修复失败：\(path)（\(detail)）"
        case .invalidRequestJSON: return "克隆请求 JSON 无效"
        case .invalidConfigFormat: return "openclaw.json 不是合法对象"
        case .cloneCancelled(let username): return "克隆已终止：\(username)"
        case .scanEncodeFailed: return "克隆扫描结果序列化失败"
        case .resultEncodeFailed: return "克隆结果序列化失败"
        }
    }
}

struct CloneClawManager {
    static let envItemID = "env"
    static let shellProfilesItemID = "shellProfiles"
    static let configItemID = "config"
    static let roleDataItemID = "roleData"

    static func scanCloneItems(sourceUsername: String) throws -> CloneScanResult {
        let home = try homeDirectory(for: sourceUsername)
        let entries: [(id: String, kind: CloneDataItemKind, title: String, relativePath: String, isDirectory: Bool)] = [
            (envItemID, .envDirectory, "基础环境", ".npm-global", true),
            (configItemID, .openclawConfig, "openclaw.json 配置", ".openclaw/openclaw.json", false),
            (roleDataItemID, .roleData, "agent 数据（auth等）", ".openclaw/agents/main/agent", true)
        ]

        var warnings: [String] = []
        var items = entries.map { entry in
            let fullPath = "\(home)/\(entry.relativePath)"
            let exists = FileManager.default.fileExists(atPath: fullPath)
            if exists {
                let size = entry.isDirectory ? directorySize(fullPath) : fileSize(fullPath)
                return CloneScanItem(
                    id: entry.id,
                    kind: entry.kind,
                    title: entry.title,
                    sourceRelativePath: entry.relativePath,
                    sizeBytes: size,
                    selectable: true,
                    selectedByDefault: true,
                    disabledReason: nil
                )
            }

            warnings.append("\(entry.title) 不存在，已自动禁用")
            return CloneScanItem(
                id: entry.id,
                kind: entry.kind,
                title: entry.title,
                sourceRelativePath: entry.relativePath,
                sizeBytes: 0,
                selectable: false,
                selectedByDefault: false,
                disabledReason: "文件或目录不存在"
            )
        }

        let shellRelativePaths = [".zprofile", ".zshrc"]
        let shellExists = shellRelativePaths.filter { FileManager.default.fileExists(atPath: "\(home)/\($0)") }
        let shellSize = shellExists.reduce(Int64(0)) { partial, relativePath in
            partial + fileSize("\(home)/\(relativePath)")
        }
        let shellSelectable = !shellExists.isEmpty
        if !shellSelectable {
            warnings.append("Shell 初始化文件不存在（.zprofile/.zshrc），已自动禁用")
        }
        items.append(
            CloneScanItem(
                id: shellProfilesItemID,
                kind: .shellProfiles,
                title: "Shell 初始化（~/.zprofile, ~/.zshrc）",
                sourceRelativePath: ".zprofile, .zshrc",
                sizeBytes: shellSize,
                selectable: shellSelectable,
                selectedByDefault: shellSelectable,
                disabledReason: shellSelectable ? nil : "文件不存在"
            )
        )

        return CloneScanResult(items: items, warnings: warnings)
    }

    static func encodeScanResult(_ result: CloneScanResult) throws -> String {
        let data = try JSONEncoder().encode(result)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CloneClawManagerError.scanEncodeFailed
        }
        return json
    }

    static func decodeRequest(_ requestJSON: String) throws -> CloneClawRequest {
        guard let data = requestJSON.data(using: .utf8),
              let request = try? JSONDecoder().decode(CloneClawRequest.self, from: data) else {
            throw CloneClawManagerError.invalidRequestJSON
        }
        return request
    }

    static func encodeResult(_ result: CloneClawResult) throws -> String {
        let data = try JSONEncoder().encode(result)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CloneClawManagerError.resultEncodeFailed
        }
        return json
    }

    static func sanitizeOpenclawConfig(_ raw: [String: Any]) -> [String: Any] {
        var root = raw
        let removePaths = [
            "channels",
            "persona",
            "preferences.persona",
            "agents.defaults.persona",
            "agents.defaults.preferences.persona",
            "agents.persona"
        ]
        for path in removePaths {
            remove(path: path, from: &root)
        }
        return normalizeConfigPaths(root)
    }

    private static func normalizeConfigPaths(_ raw: [String: Any]) -> [String: Any] {
        guard let normalized = normalizeValuePaths(raw) as? [String: Any] else { return raw }
        return normalized
    }

    private static func normalizeValuePaths(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, nested) in dict {
                out[key] = normalizeValuePaths(nested)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { normalizeValuePaths($0) }
        }
        if let string = value as? String {
            return normalizeHomePath(string)
        }
        return value
    }

    private static func normalizeHomePath(_ path: String) -> String {
        guard path.hasPrefix("/Users/") else { return path }
        let tail = String(path.dropFirst("/Users/".count))
        guard let slashIndex = tail.firstIndex(of: "/") else { return "~/" }
        return "~" + tail[slashIndex...]
    }

    private static func remove(path: String, from root: inout [String: Any]) {
        let keys = path.split(separator: ".").map(String.init)
        guard !keys.isEmpty else { return }
        remove(keys: ArraySlice(keys), from: &root)
    }

    private static func remove(keys: ArraySlice<String>, from dict: inout [String: Any]) {
        guard let first = keys.first else { return }
        if keys.count == 1 {
            dict.removeValue(forKey: first)
            return
        }
        guard var nested = dict[first] as? [String: Any] else { return }
        remove(keys: keys.dropFirst(), from: &nested)
        if nested.isEmpty {
            dict.removeValue(forKey: first)
        } else {
            dict[first] = nested
        }
    }

    static func validateUsername(_ username: String) throws {
        let regex = "^[a-z_][a-z0-9_]{0,31}$"
        let range = username.range(of: regex, options: .regularExpression)
        if range == nil {
            throw CloneClawManagerError.invalidUsername(username)
        }
    }

    static func directorySize(_ path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        let rootURL = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: rootURL,
                                             includingPropertiesForKeys: Array(keys),
                                             options: [.skipsPackageDescendants]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let rv = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if rv.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if rv.isRegularFile == true {
                total += Int64(rv.fileSize ?? 0)
            }
        }
        return total
    }

    static func fileSize(_ path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    static func homeDirectory(for username: String) throws -> String {
        guard let pw = getpwnam(username) else {
            throw CloneClawManagerError.userNotFound(username)
        }
        return String(cString: pw.pointee.pw_dir)
    }
}
