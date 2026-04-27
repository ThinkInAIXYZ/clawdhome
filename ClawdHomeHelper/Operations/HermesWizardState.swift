// ClawdHomeHelper/Operations/HermesWizardState.swift
// 进度位图读写：每个 profile 的向导完成状态持久化到 .clawdhome_wizard_state.json
//
// 文件路径：
//   main profile  → ~/.hermes/.clawdhome_wizard_state.json
//   named profile → ~/.hermes/profiles/<id>/.clawdhome_wizard_state.json
//
// schema 见设计 §4.2（2026-04-25-hermes-team-wizard-design.md）

import Foundation

struct HermesWizardState {

    // MARK: - 公开接口

    /// 读取指定 profile 的进度位图 JSON；文件不存在时返回默认骨架
    static func get(username: String, profileID: String) -> String {
        let path = statePath(username: username, profileID: profileID)
        if let data = FileManager.default.contents(atPath: path),
           let json = String(data: data, encoding: .utf8),
           !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return json
        }
        return defaultSkeleton(profileID: profileID)
    }

    /// 以 deep-merge 语义将 patchJSON 合并写入进度位图
    /// - patch 里出现的键覆盖现有；未出现的键保留
    /// - 嵌套 dict 递归 merge；嵌套 array 整体替换
    /// - updatedAt 由 helper 自动设为当前 ISO8601，除非 patch 里已提供
    static func update(username: String, profileID: String, patchJSON: String) throws {
        guard let patchData = patchJSON.data(using: .utf8),
              let patch = try? JSONSerialization.jsonObject(with: patchData) as? [String: Any] else {
            throw HermesWizardStateError.invalidPatchJSON
        }

        let path = statePath(username: username, profileID: profileID)

        // 读取现有状态（若文件不存在则从骨架开始）
        var current: [String: Any]
        if let data = FileManager.default.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            current = obj
        } else {
            let skeletonData = Data(defaultSkeleton(profileID: profileID).utf8)
            current = (try? JSONSerialization.jsonObject(with: skeletonData) as? [String: Any]) ?? [:]
        }

        // 若 patch 未显式设置 updatedAt，则注入当前时间
        var effectivePatch = patch
        if effectivePatch["updatedAt"] == nil {
            effectivePatch["updatedAt"] = iso8601Now()
        }

        let merged = deepMerge(current, effectivePatch)

        // 原子写入
        let mergedData = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys, .prettyPrinted])
        try atomicWrite(mergedData, to: path, username: username)
    }

    /// 清除进度位图（重置为默认骨架），保留文件权限设置
    static func clear(username: String, profileID: String) throws {
        let path = statePath(username: username, profileID: profileID)
        let skeleton = defaultSkeleton(profileID: profileID)
        guard let data = skeleton.data(using: .utf8) else {
            throw HermesWizardStateError.serializationFailed
        }
        try atomicWrite(data, to: path, username: username)
    }

    // MARK: - 私有辅助

    private static func statePath(username: String, profileID: String) -> String {
        let hermesHome = HermesGatewayManager.hermesHomeForProfile(username: username, profileID: profileID)
        return "\(hermesHome)/.clawdhome_wizard_state.json"
    }

    /// 默认骨架（文件缺失时返回）
    private static func defaultSkeleton(profileID: String) -> String {
        let now = iso8601Now()
        return """
        {
          "schemaVersion": 1,
          "profileID": "\(profileID)",
          "createdAt": "\(now)",
          "updatedAt": "\(now)",
          "steps": {
            "profileCreated": false,
            "modelConfigured": false,
            "imBindings": {},
            "doctorPassed": false,
            "gatewayInstalled": false,
            "gatewayStarted": false
          }
        }
        """
    }

    /// 深度合并两个 JSON 对象（字典递归合并；数组整体替换）
    private static func deepMerge(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var result = base
        for (key, patchValue) in patch {
            if let baseDict = result[key] as? [String: Any],
               let patchDict = patchValue as? [String: Any] {
                result[key] = deepMerge(baseDict, patchDict)
            } else {
                result[key] = patchValue
            }
        }
        return result
    }

    /// 原子写入，chmod 600 + chown 到目标用户
    private static func atomicWrite(_ data: Data, to path: String, username: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: parent) {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let tmp = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        // 替换目标文件
        _ = try? fm.removeItem(atPath: path)
        try fm.moveItem(atPath: tmp, toPath: path)
        _ = try? FilePermissionHelper.chown(path, owner: username)
        _ = try? FilePermissionHelper.chmod(path, mode: "600")
    }

    private static func iso8601Now() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: Date())
    }
}

// MARK: - 错误类型

enum HermesWizardStateError: LocalizedError {
    case invalidPatchJSON
    case serializationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPatchJSON:
            return "进度位图 patch JSON 解析失败"
        case .serializationFailed:
            return "进度位图序列化失败"
        }
    }
}
