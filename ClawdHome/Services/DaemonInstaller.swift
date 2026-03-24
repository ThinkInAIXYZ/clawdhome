// ClawdHome/Services/DaemonInstaller.swift
// 封装 SMAppService daemon 的注册与状态查询

import Foundation
import ServiceManagement
import Observation

@Observable
final class DaemonInstaller {
    private static let plistName = "ai.clawdhome.mac.helper.plist"
    private let service = SMAppService.daemon(plistName: DaemonInstaller.plistName)

    /// daemon 当前注册状态
    var status: SMAppService.Status {
        service.status
    }

    /// 是否已注册并启用
    var isEnabled: Bool {
        service.status == .enabled
    }

    /// 状态描述，用于 UI 展示
    var statusDescription: String {
        switch service.status {
        case .notRegistered:    return L10n.k("services.daemon_installer.not_installed", fallback: "未安装")
        case .enabled:          return L10n.k("services.daemon_installer.run", fallback: "已安装并运行")
        case .requiresApproval: return L10n.k("services.daemon_installer.waitinguser_settings", fallback: "等待用户授权（系统设置→登录项）")
        case .notFound:         return L10n.k("services.daemon_installer.app_bundle", fallback: "未找到（请检查 app bundle）")
        @unknown default:       return L10n.k("services.daemon_installer.unknownstatus", fallback: "未知状态")
        }
    }

    /// 注册 LaunchDaemon（首次调用会弹出系统授权对话框）
    /// 必须在主线程调用
    func install() throws {
        try service.register()
    }

    /// 注销 LaunchDaemon
    func uninstall() throws {
        try service.unregister()
    }

    /// 刷新状态（供强制 UI 刷新用）
    func refresh() {
        _ = service.status
    }
}
