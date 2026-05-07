// ClawdHomeHelper/Operations/FilePermissionHelper.swift
// 文件权限与归属操作的统一封装，消除 chown/chmod 调用散布

import Foundation

enum FilePermissionHelper {

    // MARK: - 归属（chown）

    /// 将文件/目录归属给指定用户（非递归）
    @discardableResult
    static func chown(_ path: String, owner: String) throws -> String {
        try run("/usr/sbin/chown", args: [owner, path])
    }

    /// 递归将目录归属给指定用户
    @discardableResult
    static func chownRecursive(_ path: String, owner: String) throws -> String {
        try run("/usr/sbin/chown", args: ["-R", owner, path])
    }

    /// 将文件归属给 owner:group
    @discardableResult
    static func chown(_ path: String, owner: String, group: String) throws -> String {
        try run("/usr/sbin/chown", args: ["\(owner):\(group)", path])
    }

    // MARK: - 权限（chmod）

    /// 设置文件权限（数字模式，如 "700"、"644"）
    @discardableResult
    static func chmod(_ path: String, mode: String) throws -> String {
        try run("/bin/chmod", args: [mode, path])
    }

    /// 递归设置目录权限
    @discardableResult
    static func chmodRecursive(_ path: String, mode: String) throws -> String {
        try run("/bin/chmod", args: ["-R", mode, path])
    }

    /// 符号模式 chmod（如 "go-rwx"、"o-w"）
    @discardableResult
    static func chmodSymbolic(_ path: String, expr: String) throws -> String {
        try run("/bin/chmod", args: [expr, path])
    }

    /// 递归符号模式 chmod
    @discardableResult
    static func chmodSymbolicRecursive(_ path: String, expr: String) throws -> String {
        try run("/bin/chmod", args: ["-R", expr, path])
    }

    // MARK: - 常用组合

    /// 归属给用户 + 设置权限（常见于目录创建后）
    static func chownAndChmod(_ path: String, owner: String, mode: String) throws {
        try chown(path, owner: owner)
        try chmod(path, mode: mode)
    }

    /// 递归归属给用户 + 设置权限
    static func chownAndChmodRecursive(_ path: String, owner: String, mode: String) throws {
        try chownRecursive(path, owner: owner)
        try chmodRecursive(path, mode: mode)
    }

    /// 设置为 root:wheel 644（适用于 LaunchDaemon plist）
    static func setRootPlistPermissions(_ path: String) throws {
        try chown(path, owner: "root", group: "wheel")
        try chmod(path, mode: "644")
    }

    /// 设置为用户私有目录（owner rwx，其他无权限）
    static func setUserPrivateDirectory(_ path: String, owner: String) throws {
        try chown(path, owner: owner)
        try chmod(path, mode: "700")
    }

    // MARK: - 清除 ACL

    /// 移除文件的 ACL（chmod -N）
    @discardableResult
    static func clearACL(_ path: String) throws -> String {
        try run("/bin/chmod", args: ["-N", path])
    }
}
