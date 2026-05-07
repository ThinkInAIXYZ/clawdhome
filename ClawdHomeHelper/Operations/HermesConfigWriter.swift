// ClawdHomeHelper/Operations/HermesConfigWriter.swift
// 写入/校验 Hermes 初始化配置（config.yaml + .env）

import Foundation

struct HermesConfigWriter {
    struct InitPayload: Codable {
        var provider: String?
        var modelDefault: String?
        var modelBaseURL: String?
        var modelAPIMode: String?
        var env: [String: String]?
        var agent: AgentConfig?
    }

    struct AgentConfig: Codable {
        var gateway_timeout: Int?
        var gateway_notify_interval: Int?
        var gateway_timeout_warning: Int?
    }

    static func apply(username: String, profileID: String, payloadJSON: String) throws {
        let payload = try decodePayload(payloadJSON)
        let hermesHome = HermesGatewayManager.hermesHomeForProfile(username: username, profileID: profileID)
        try ensureHermesHome(username: username, hermesHome: hermesHome)

        // 收集 model / agent section 更新
        var modelUpdates: [String: String] = [:]
        if let v = normalized(payload.provider) { modelUpdates["provider"] = v }
        if let v = normalized(payload.modelDefault) { modelUpdates["default"] = v }
        if let v = normalized(payload.modelBaseURL) { modelUpdates["base_url"] = v }
        if let v = normalized(payload.modelAPIMode) { modelUpdates["api_mode"] = v }

        var agentUpdates: [String: String] = [:]
        if let agent = payload.agent {
            if let v = agent.gateway_timeout { agentUpdates["gateway_timeout"] = "\(v)" }
            if let v = agent.gateway_notify_interval { agentUpdates["gateway_notify_interval"] = "\(v)" }
            if let v = agent.gateway_timeout_warning { agentUpdates["gateway_timeout_warning"] = "\(v)" }
        }

        // 原子写入 config.yaml（读取现有内容 → 修补 → 写回，保留未管理的 section）
        let configPath = "\(hermesHome)/config.yaml"
        if !modelUpdates.isEmpty || !agentUpdates.isEmpty {
            let existing = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
            let patched = patchYAMLSections(existing, sections: [
                ("model", modelUpdates),
                ("agent", agentUpdates),
            ])
            try patched.write(toFile: configPath, atomically: true, encoding: .utf8)
            _ = try? FilePermissionHelper.chown(configPath, owner: username)
            _ = try? FilePermissionHelper.chmod(configPath, mode: "600")
        }

        // 合并 .env
        if let envUpdates = payload.env, !envUpdates.isEmpty {
            try mergeEnv(
                username: username,
                envPath: "\(hermesHome)/.env",
                updates: envUpdates
            )
        }
    }

    /// 向后兼容重载：profileID 默认为 "main"
    static func apply(username: String, payloadJSON: String) throws {
        try apply(username: username, profileID: "main", payloadJSON: payloadJSON)
    }

    static func initSummaryJSON(username: String, profileID: String) -> String {
        let hermesHome = HermesGatewayManager.hermesHomeForProfile(username: username, profileID: profileID)
        let configPath = "\(hermesHome)/config.yaml"
        let envPath = "\(hermesHome)/.env"
        let model = parseModelSection(configPath: configPath)
        let env = loadEnv(path: envPath)
        let summary: [String: Any] = [
            "version": HermesInstaller.installedVersion(username: username) ?? "",
            "provider": model["provider"] ?? "",
            "modelDefault": model["default"] ?? "",
            "modelBaseURL": model["base_url"] ?? "",
            "modelAPIMode": model["api_mode"] ?? "",
            "envKeyCount": env.count,
            "envKeys": Array(env.keys).sorted(),
            "configPath": configPath,
            "envPath": envPath,
            "gatewayStatePath": "\(hermesHome)/gateway_state.json",
            "profileID": profileID,
        ]
        return toJSONString(summary, fallback: "{}")
    }

    /// 向后兼容重载：profileID 默认为 "main"
    static func initSummaryJSON(username: String) -> String {
        initSummaryJSON(username: username, profileID: "main")
    }

    static func validateJSON(username: String, profileID: String) -> String {
        let hermesHome = HermesGatewayManager.hermesHomeForProfile(username: username, profileID: profileID)
        let configPath = "\(hermesHome)/config.yaml"
        let envPath = "\(hermesHome)/.env"
        let installed = HermesInstaller.installedVersion(username: username) != nil
        let configExists = FileManager.default.fileExists(atPath: configPath)
        let envExists = FileManager.default.fileExists(atPath: envPath)
        let model = parseModelSection(configPath: configPath)
        let env = loadEnv(path: envPath)

        var issues: [[String: String]] = []
        if !installed {
            issues.append(["code": "hermes_not_installed", "level": "error", "message": "Hermes 未安装"])
        }
        if !configExists {
            issues.append(["code": "config_missing", "level": "error", "message": "config.yaml 缺失"])
        }
        if !envExists {
            issues.append(["code": "env_missing", "level": "warn", "message": ".env 缺失"])
        }
        let provider = normalized(model["provider"])
        if provider == nil {
            issues.append(["code": "model_provider_missing", "level": "error", "message": "model.provider 未配置"])
        }
        if normalized(model["default"]) == nil {
            issues.append(["code": "model_default_missing", "level": "error", "message": "model.default 未配置"])
        }
        if provider == "custom", normalized(model["base_url"]) == nil {
            issues.append(["code": "custom_base_url_missing", "level": "error", "message": "provider=custom 但 model.base_url 为空"])
        }

        for (k, v) in env where isSecretLikeKey(k) && looksLikePlaceholder(v) {
            issues.append([
                "code": "placeholder_secret",
                "level": "warn",
                "message": "\(k) 仍为占位值"
            ])
        }

        let valid = !issues.contains { $0["level"] == "error" }
        let report: [String: Any] = [
            "valid": valid,
            "issues": issues,
            "checks": [
                "hermesInstalled": installed,
                "configExists": configExists,
                "envExists": envExists,
                "providerConfigured": provider != nil,
                "modelConfigured": normalized(model["default"]) != nil,
            ],
            "summary": [
                "version": HermesInstaller.installedVersion(username: username) ?? "",
                "provider": provider ?? "",
                "modelDefault": normalized(model["default"]) ?? "",
            ],
        ]
        return toJSONString(report, fallback: #"{"valid":false,"issues":[{"code":"serialize_failed","level":"error","message":"JSON 序列化失败"}]}"#)
    }

    /// 向后兼容重载：profileID 默认为 "main"
    static func validateJSON(username: String) -> String {
        validateJSON(username: username, profileID: "main")
    }

    /// IM 绑定专用写入入口（供 applyHermesIMBinding 使用，不暴露底层 mergeEnv）
    /// 将给定 env 字典原子合并写入 profile 的 .env 文件
    static func writeIMBindingEnv(
        username: String,
        profileID: String,
        platform: String,
        env: [String: String]
    ) throws {
        let hermesHome = HermesGatewayManager.hermesHomeForProfile(username: username, profileID: profileID)
        let envPath = "\(hermesHome)/.env"
        try mergeEnv(username: username, envPath: envPath, updates: env)
    }

    private static func decodePayload(_ payloadJSON: String) throws -> InitPayload {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw HermesConfigError.invalidPayload("payload 非 UTF-8 文本")
        }
        do {
            return try JSONDecoder().decode(InitPayload.self, from: data)
        } catch {
            throw HermesConfigError.invalidPayload("payload JSON 解析失败：\(error.localizedDescription)")
        }
    }

    private static func ensureHermesHome(username: String, hermesHome: String) throws {
        if !FileManager.default.fileExists(atPath: hermesHome) {
            try FileManager.default.createDirectory(
                atPath: hermesHome,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        _ = try? FilePermissionHelper.chownRecursive(hermesHome, owner: username)
    }

    /// 逐行修补 YAML 的指定顶层 section（保留注释、空行、未管理的 section）
    private static func patchYAMLSections(
        _ yaml: String,
        sections: [(name: String, keys: [String: String])]
    ) -> String {
        var lines = yaml.components(separatedBy: "\n")

        for (sectionName, keyUpdates) in sections where !keyUpdates.isEmpty {
            var sectionStart: Int?
            var sectionEnd: Int?
            var sectionIndent = 0

            for (i, rawLine) in lines.enumerated() {
                let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let indent = line.prefix(while: { $0 == " " }).count

                if sectionStart == nil {
                    if trimmed == "\(sectionName):" {
                        sectionStart = i
                        sectionIndent = indent
                    }
                } else if indent <= sectionIndent {
                    sectionEnd = i
                    break
                }
            }

            if let start = sectionStart {
                let end = sectionEnd ?? lines.count
                let childIndent = String(repeating: " ", count: sectionIndent + 2)
                var updatedKeys = Set<String>()
                var lastKeyLine = start

                for i in (start + 1)..<end {
                    let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                    let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    lastKeyLine = i
                    if let newValue = keyUpdates[key] {
                        lines[i] = "\(childIndent)\(key): \(renderYAMLValue(newValue))"
                        updatedKeys.insert(key)
                    }
                }

                // 追加 section 中不存在的新 key
                var offset = 0
                for key in keyUpdates.keys.sorted() where !updatedKeys.contains(key) {
                    offset += 1
                    lines.insert(
                        "\(childIndent)\(key): \(renderYAMLValue(keyUpdates[key]!))",
                        at: lastKeyLine + offset
                    )
                }
            } else {
                // section 不存在，追加到文件末尾
                if let last = lines.last, !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("")
                }
                lines.append("\(sectionName):")
                for key in keyUpdates.keys.sorted() {
                    lines.append("  \(key): \(renderYAMLValue(keyUpdates[key]!))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// YAML 值渲染：包含歧义字符时用双引号包裹
    private static func renderYAMLValue(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.contains(": ") || value.contains(" #") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return value
    }

    private static func mergeEnv(
        username: String,
        envPath: String,
        updates: [String: String]
    ) throws {
        let fm = FileManager.default
        let parent = (envPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        let existing = (try? String(contentsOfFile: envPath, encoding: .utf8)) ?? ""
        var replacedKeys = Set<String>()
        var lines: [String] = []

        for line in existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || !line.contains("=") {
                lines.append(line)
                continue
            }
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard let rawKey = pair.first else {
                lines.append(line)
                continue
            }
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                lines.append(line)
                continue
            }
            if let newValue = updates[key] {
                lines.append("\(key)=\(renderEnvValue(newValue))")
                replacedKeys.insert(key)
            } else {
                lines.append(line)
            }
        }

        for key in updates.keys.sorted() where !replacedKeys.contains(key) {
            lines.append("\(key)=\(renderEnvValue(updates[key] ?? ""))")
        }

        let out = lines.joined(separator: "\n")
        try out.write(toFile: envPath, atomically: true, encoding: .utf8)
        _ = try? FilePermissionHelper.chown(envPath, owner: username)
        _ = try? FilePermissionHelper.chmod(envPath, mode: "600")
    }

    private static func renderEnvValue(_ value: String) -> String {
        if value.isEmpty { return "" }
        let needsQuote = value.contains(" ") || value.contains("#") || value.contains("\"")
        guard needsQuote else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func parseModelSection(configPath: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return [:]
        }
        var result: [String: String] = [:]
        var inModel = false
        var modelIndent = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if !inModel {
                if trimmed == "model:" {
                    inModel = true
                    modelIndent = indent
                }
                continue
            }
            if indent <= modelIndent {
                inModel = false
                continue
            }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if ["provider", "default", "base_url", "api_mode"].contains(key) {
                result[key] = value
            }
        }
        return result
    }

    private static func loadEnv(path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var env: [String: String] = [:]
        for line in text.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            env[key] = value
        }
        return env
    }

    private static func isSecretLikeKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return upper.hasSuffix("_API_KEY") || upper.hasSuffix("_TOKEN") || upper.hasSuffix("_SECRET")
    }

    private static func looksLikePlaceholder(_ value: String) -> Bool {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty { return false }
        if lowered.contains("changeme") || lowered.contains("replace_me") { return true }
        if lowered.contains("your_") || lowered.hasPrefix("<") || lowered.hasPrefix("xxx") { return true }
        if lowered.contains("example") || lowered.contains("placeholder") { return true }
        return false
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func toJSONString(_ obj: Any, fallback: String) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return text
    }
}

enum HermesConfigError: LocalizedError {
    case invalidPayload(String)
    case hermesExecutableMissing

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let reason):
            return reason
        case .hermesExecutableMissing:
            return "未找到 Hermes 可执行文件，请先安装 Hermes。"
        }
    }
}

// MARK: - Hermes profile management

enum HermesProfileError: LocalizedError {
    case invalidProfileID(String)
    case profileMissing(String)
    case invalidProfileJSON
    case cannotRemoveMain

    var errorDescription: String? {
        switch self {
        case .invalidProfileID(let id):
            return "非法 profile id：\(id)"
        case .profileMissing(let id):
            return "profile 不存在：\(id)"
        case .invalidProfileJSON:
            return "profile JSON 解析失败"
        case .cannotRemoveMain:
            return "不能删除 main/default profile"
        }
    }
}

struct HermesProfileManager {
    private struct AgentProfileDTO: Codable {
        var id: String
        var name: String
        var emoji: String
        var modelPrimary: String?
        var modelProvider: String?
        var modelFallbacks: [String]
        var workspacePath: String?
        var isDefault: Bool
        var skillCount: Int?
        var gatewayRunning: Bool?
    }

    private struct ProfileMeta: Codable {
        var name: String
        var emoji: String
    }

    private static let profileDirs = [
        "memories",
        "sessions",
        "skills",
        "skins",
        "logs",
        "plans",
        "workspace",
        "cron",
        "home",
    ]

    private static let cloneConfigFiles = [
        "config.yaml",
        ".env",
        "SOUL.md",
        "memories/MEMORY.md",
        "memories/USER.md",
    ]
    private static let sharedFolderMarker = "~/clawdhome_shared/private/"
    private static let defaultSavePolicy = """
    ## File Save Policy

    - When asked to save files, export results, or generate reports, write to `~/clawdhome_shared/private/` first.
    - Use `~/clawdhome_shared/public/` only for non-sensitive shared resources.
    - Do not write sensitive data to the public folder.
    """

    static func listProfiles(username: String) throws -> String {
        let hermesHome = HermesInstaller.hermesHome(for: username)
        try ensureHermesHome(username: username, hermesHome: hermesHome)

        let activeID = activeProfileID(username: username)
        let gatewayState = HermesGatewayManager.status(username: username)
        let metas = loadMetaMap(hermesHome: hermesHome)
        var ids: [String] = ["main"]

        let root = "\(hermesHome)/profiles"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: root) {
            let named = entries.filter { isValidNamedProfileID($0) }.sorted()
            ids.append(contentsOf: named)
        }

        let profiles = ids.map { id -> AgentProfileDTO in
            let meta = metas[id]
            let defaultName = (id == "main") ? "默认角色" : id
            let defaultEmoji = (id == "main") ? "🎭" : "🤖"
            let root = profileRootPath(hermesHome: hermesHome, profileID: id)
            let model = parseModelSection(configPath: "\(root)/config.yaml")
            return AgentProfileDTO(
                id: id,
                name: normalized(meta?.name) ?? defaultName,
                emoji: normalized(meta?.emoji) ?? defaultEmoji,
                modelPrimary: normalized(model["default"]),
                modelProvider: normalized(model["provider"]),
                modelFallbacks: [],
                workspacePath: root,
                isDefault: (id == activeID),
                skillCount: countSkills(profileRoot: root),
                gatewayRunning: (id == activeID ? gatewayState.running : false)
            )
        }

        let data = try JSONEncoder().encode(profiles)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func createProfile(username: String, configJSON: String) throws {
        guard let data = configJSON.data(using: .utf8),
              let profile = try? JSONDecoder().decode(AgentProfileDTO.self, from: data) else {
            throw HermesProfileError.invalidProfileJSON
        }
        try validateProfileID(profile.id)

        let hermesHome = HermesInstaller.hermesHome(for: username)
        try ensureHermesHome(username: username, hermesHome: hermesHome)
        var metas = loadMetaMap(hermesHome: hermesHome)
        let id = profile.id
        let profileName = normalized(profile.name) ?? ((id == "main") ? "默认角色" : id)
        let profileEmoji = normalized(profile.emoji) ?? ((id == "main") ? "🎭" : "🤖")
        metas[id] = ProfileMeta(name: profileName, emoji: profileEmoji)

        if id != "main" {
            let dir = profileDir(hermesHome: hermesHome, profileID: id)
            if !FileManager.default.fileExists(atPath: dir) {
                try FileManager.default.createDirectory(
                    atPath: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                for subdir in profileDirs {
                    try FileManager.default.createDirectory(
                        atPath: "\(dir)/\(subdir)",
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                }
                try cloneDefaultProfileConfigIfNeeded(username: username, hermesHome: hermesHome, profileID: id)
            }
            // 新建或已存在的命名 profile 默认加入自启白名单（D12：新 profile 默认进白名单）
            // id="main" 不显式追加：由 HermesAutostartList.load 的兜底语义（缺失文件 → ["main"]）覆盖
            try? HermesAutostartList.add(username: username, profileID: id)
        }
        try ensureSoulSavePolicy(username: username, hermesHome: hermesHome, profileID: id)

        try saveMetaMap(metas, hermesHome: hermesHome, username: username)
        if profile.isDefault {
            try setActiveProfile(username: username, profileID: id)
        } else {
            _ = try? FilePermissionHelper.chownRecursive(hermesHome, owner: username)
        }
    }

    static func activeProfileID(username: String) -> String {
        let hermesHome = HermesInstaller.hermesHome(for: username)
        let activePath = "\(hermesHome)/active_profile"
        guard let raw = try? String(contentsOfFile: activePath, encoding: .utf8) else {
            return "main"
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidNamedProfileID(trimmed) else {
            return "main"
        }
        let dir = profileDir(hermesHome: hermesHome, profileID: trimmed)
        return FileManager.default.fileExists(atPath: dir) ? trimmed : "main"
    }

    static func setActiveProfile(username: String, profileID: String) throws {
        try validateProfileID(profileID)
        let hermesHome = HermesInstaller.hermesHome(for: username)
        try ensureHermesHome(username: username, hermesHome: hermesHome)
        let activePath = "\(hermesHome)/active_profile"

        if profileID == "main" {
            if FileManager.default.fileExists(atPath: activePath) {
                try FileManager.default.removeItem(atPath: activePath)
            }
            _ = try? FilePermissionHelper.chownRecursive(hermesHome, owner: username)
            return
        }

        let dir = profileDir(hermesHome: hermesHome, profileID: profileID)
        guard FileManager.default.fileExists(atPath: dir) else {
            throw HermesProfileError.profileMissing(profileID)
        }

        try atomicWrite(profileID + "\n", to: activePath)
        _ = try? FilePermissionHelper.chown(activePath, owner: username)
        _ = try? FilePermissionHelper.chmod(activePath, mode: "600")
        _ = try? FilePermissionHelper.chownRecursive(hermesHome, owner: username)
    }

    static func removeProfile(username: String, profileID: String) throws {
        try validateProfileID(profileID)
        guard profileID != "main" else {
            throw HermesProfileError.cannotRemoveMain
        }
        let hermesHome = HermesInstaller.hermesHome(for: username)
        try ensureHermesHome(username: username, hermesHome: hermesHome)
        let dir = profileDir(hermesHome: hermesHome, profileID: profileID)
        guard FileManager.default.fileExists(atPath: dir) else {
            throw HermesProfileError.profileMissing(profileID)
        }

        let current = activeProfileID(username: username)
        if current == profileID {
            try setActiveProfile(username: username, profileID: "main")
        }

        try FileManager.default.removeItem(atPath: dir)
        var metas = loadMetaMap(hermesHome: hermesHome)
        metas.removeValue(forKey: profileID)
        try saveMetaMap(metas, hermesHome: hermesHome, username: username)
        // 删除 profile 时同步从自启白名单剔除（D12 联动）
        _ = try? HermesAutostartList.remove(username: username, profileID: profileID)
        _ = try? FilePermissionHelper.chownRecursive(hermesHome, owner: username)
    }

    private static func validateProfileID(_ id: String) throws {
        if id == "main" { return }
        guard isValidNamedProfileID(id) else {
            throw HermesProfileError.invalidProfileID(id)
        }
    }

    private static func isValidNamedProfileID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first else { return false }
        let lower = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        guard lower.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) } && id.count <= 64
    }

    private static func profileDir(hermesHome: String, profileID: String) -> String {
        "\(hermesHome)/profiles/\(profileID)"
    }

    private static func profileRootPath(hermesHome: String, profileID: String) -> String {
        if profileID == "main" {
            return hermesHome
        }
        return profileDir(hermesHome: hermesHome, profileID: profileID)
    }

    private static func workspacePath(username: String, profileID: String) -> String {
        if profileID == "main" {
            return "/Users/\(username)/.hermes"
        }
        return "/Users/\(username)/.hermes/profiles/\(profileID)"
    }

    private static func metaPath(hermesHome: String) -> String {
        "\(hermesHome)/.clawdhome_profile_meta.json"
    }

    private static func loadMetaMap(hermesHome: String) -> [String: ProfileMeta] {
        let path = metaPath(hermesHome: hermesHome)
        guard let data = FileManager.default.contents(atPath: path),
              let map = try? JSONDecoder().decode([String: ProfileMeta].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func saveMetaMap(_ map: [String: ProfileMeta], hermesHome: String, username: String) throws {
        let path = metaPath(hermesHome: hermesHome)
        let data = try JSONEncoder().encode(map)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        _ = try? FilePermissionHelper.chown(path, owner: username)
        _ = try? FilePermissionHelper.chmod(path, mode: "600")
    }

    private static func cloneDefaultProfileConfigIfNeeded(
        username: String,
        hermesHome: String,
        profileID: String
    ) throws {
        let dstRoot = profileDir(hermesHome: hermesHome, profileID: profileID)
        for rel in cloneConfigFiles {
            let src = "\(hermesHome)/\(rel)"
            guard FileManager.default.fileExists(atPath: src) else { continue }
            let dst = "\(dstRoot)/\(rel)"
            let parent = (dst as NSString).deletingLastPathComponent
            if !FileManager.default.fileExists(atPath: parent) {
                try FileManager.default.createDirectory(
                    atPath: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            if !FileManager.default.fileExists(atPath: dst) {
                try FileManager.default.copyItem(atPath: src, toPath: dst)
            }
        }
        _ = try? FilePermissionHelper.chownRecursive(dstRoot, owner: username)
    }

    private static func atomicWrite(_ text: String, to path: String) throws {
        let tmp = path + ".tmp"
        try text.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: tmp, toPath: path)
    }

    private static func ensureSoulSavePolicy(username: String, hermesHome: String, profileID: String) throws {
        let root = profileRootPath(hermesHome: hermesHome, profileID: profileID)
        let soulPath = "\(root)/SOUL.md"
        let existing = (try? String(contentsOfFile: soulPath, encoding: .utf8)) ?? ""
        if existing.contains(sharedFolderMarker) { return }

        let updated = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultSavePolicy
            : existing + "\n\n" + defaultSavePolicy
        try updated.write(toFile: soulPath, atomically: true, encoding: .utf8)
        _ = try? FilePermissionHelper.chown(soulPath, owner: username)
        _ = try? FilePermissionHelper.chmod(soulPath, mode: "600")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func ensureHermesHome(username: String, hermesHome: String) throws {
        if !FileManager.default.fileExists(atPath: hermesHome) {
            try FileManager.default.createDirectory(
                atPath: hermesHome,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        _ = try? FilePermissionHelper.chownRecursive(hermesHome, owner: username)
    }

    private static func parseModelSection(configPath: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return [:]
        }
        var result: [String: String] = [:]
        var inModel = false
        var modelIndent = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if !inModel {
                if trimmed == "model:" {
                    inModel = true
                    modelIndent = indent
                }
                continue
            }
            if indent <= modelIndent {
                inModel = false
                continue
            }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if ["provider", "default"].contains(key) {
                result[key] = value
            }
        }
        return result
    }

    private static func countSkills(profileRoot: String) -> Int {
        let skillsDir = "\(profileRoot)/skills"
        guard let enumerator = FileManager.default.enumerator(atPath: skillsDir) else {
            return 0
        }
        var count = 0
        while let item = enumerator.nextObject() as? String {
            if item.hasSuffix("/SKILL.md") || item == "SKILL.md" {
                count += 1
            }
        }
        return count
    }
}
