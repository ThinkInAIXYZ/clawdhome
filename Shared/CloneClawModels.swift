import Foundation

/// 克隆新虾：可勾选的数据项类型
enum CloneDataItemKind: String, Codable, Sendable, Hashable {
    case envDirectory
    case shellProfiles
    case openclawConfig
    // 兼容旧版 helper 返回值：新版本不再使用这两类克隆项
    case secrets
    case authProfiles
    case roleData
}

/// 克隆扫描结果中的单项数据
struct CloneScanItem: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let kind: CloneDataItemKind
    let title: String
    let sourceRelativePath: String
    let sizeBytes: Int64
    let selectable: Bool
    let selectedByDefault: Bool
    let disabledReason: String?
}

/// 克隆前扫描返回结果
struct CloneScanResult: Codable, Sendable, Hashable {
    let items: [CloneScanItem]
    let warnings: [String]
}

/// 克隆执行请求
struct CloneClawRequest: Codable, Sendable, Hashable {
    let sourceUsername: String
    let targetUsername: String
    let targetFullName: String
    let selectedItemIDs: [String]
    let openWebUIAfterClone: Bool
    /// 可选：由 App 生成并保存到 Keychain 后传入，确保目标用户密码可回显。
    let targetPassword: String?
}

/// 克隆执行结果
struct CloneClawResult: Codable, Sendable, Hashable {
    let targetUsername: String
    let gatewayURL: String
    let warnings: [String]
}

enum CloneClawSelection {
    static func defaultSelectedIDs(items: [CloneScanItem]) -> Set<String> {
        Set(items.filter { $0.selectable && $0.selectedByDefault }.map(\.id))
    }

    static func selectedSize(items: [CloneScanItem], selectedIDs: Set<String>) -> Int64 {
        items.reduce(0) { partial, item in
            selectedIDs.contains(item.id) ? partial + item.sizeBytes : partial
        }
    }
}
