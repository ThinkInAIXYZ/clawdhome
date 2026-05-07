// ClawdHome/Services/UserDirectoryService.swift
// 通过 OpenDirectory 框架读取本机标准用户列表（只读，无需 XPC）

import Foundation
import OpenDirectory

struct UserDirectoryService {

    /// 列出本机所有标准用户（uid ≥ 500，排除系统账户及 _ 开头的服务账户）
    private static func listStandardUsers() throws -> [UserRecord] {
        let session = ODSession.default()
        let node = try ODNode(session: session, type: ODNodeType(kODNodeTypeLocalNodes))

        // 提前查询 admin 组成员列表，用于标记管理员
        let adminMembers = fetchAdminGroupMembers(node: node)

        // kODMatchAny 返回所有记录，在 Swift 侧按 UID 过滤
        let query = try ODQuery(
            node: node,
            forRecordTypes: kODRecordTypeUsers,
            attribute: kODAttributeTypeRecordName,
            matchType: ODMatchType(kODMatchAny),
            queryValues: nil,
            returnAttributes: [kODAttributeTypeFullName, kODAttributeTypeUniqueID],
            maximumResults: 0
        )

        guard let results = try query.resultsAllowingPartial(false) as? [ODRecord] else {
            return []
        }

        return results.compactMap { record -> UserRecord? in
            guard
                let username = record.recordName,
                let uidValues = try? record.values(forAttribute: kODAttributeTypeUniqueID),
                let uidStr = uidValues.first as? String,
                let uid = Int(uidStr),
                ManagedUserFilter.isEligibleManagedUser(
                    username: username,
                    uid: uid,
                    adminNames: []
                )                                       // 只保留标准用户（管理员仅标记，不排除）
            else { return nil }

            let fullName = (try? record.values(forAttribute: kODAttributeTypeFullName))?
                .first as? String ?? username

            return UserRecord(
                username: username,
                fullName: fullName,
                uid: uid,
                isAdmin: adminMembers.contains(username)
            )
        }
        .sorted { $0.uid < $1.uid }
    }

    /// 异步版本：在 utility QoS 线程上执行 OpenDirectory 查询。
    /// OpenDirectory 内部常驻队列通常是 Default QoS，若调用方在更高 QoS（如 userInitiated）
    /// 执行并同步等待，会触发 Thread Performance Checker 的优先级倒置告警。
    static func listStandardUsersAsync() async throws -> [UserRecord] {
        try await Task.detached(priority: .utility) {
            try listStandardUsers()
        }.value
    }

    /// 查询 admin 组的成员短名称列表（查询失败时返回空集合）
    /// 注意：由 listStandardUsersAsync 调度到 utility QoS 上执行，避免高 QoS 线程等待默认 QoS。
    private static func fetchAdminGroupMembers(node: ODNode) -> Set<String> {
        guard
            let record = try? node.record(
                withRecordType: kODRecordTypeGroups,
                name: "admin",
                attributes: [kODAttributeTypeGroupMembership]
            ),
            let values = try? record.values(forAttribute: kODAttributeTypeGroupMembership)
                as? [String]
        else { return [] }
        return Set(values)
    }
}

/// OpenDirectory 查询结果（轻量值类型）
struct UserRecord {
    let username: String
    let fullName: String
    let uid: Int
    let isAdmin: Bool
}
