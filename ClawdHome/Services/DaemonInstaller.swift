// ClawdHome/Services/DaemonInstaller.swift
// 封装 SMAppService daemon 的注册与状态查询
//
// ⚠️ DEBUG 模式注意事项：
// SMAppService 会在 app 启动时自动检测 app bundle 内嵌的 helper 是否有变化，
// 如果有就替换 /Library/PrivilegedHelperTools/ 中正在运行的二进制。
// 在 Xcode 开发循环中，每次 build 都会重新编译 helper 并嵌入 app bundle，
// 导致 SMAppService 反复替换运行中的 helper → SIGKILL: Invalid Page。
// 因此 DEBUG 模式下禁用 SMAppService，改用 `make install-helper` 手动管理。

import Foundation
import ServiceManagement
import Observation
import os.log

@Observable
final class DaemonInstaller {
    private static let plistName = "ai.clawdhome.mac.helper.plist"
    private let service = SMAppService.daemon(plistName: DaemonInstaller.plistName)

    /// DEBUG 模式下不使用 SMAppService，避免每次 build 后自动替换 helper 二进制
    static let isDevMode: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// daemon 当前注册状态
    var status: SMAppService.Status {
        if Self.isDevMode { return .enabled }
        return service.status
    }

    /// 是否已注册并启用
    var isEnabled: Bool {
        if Self.isDevMode { return true }
        return service.status == .enabled
    }

    /// 状态描述，用于 UI 展示
    var statusDescription: String {
        if Self.isDevMode {
            return L10n.k("services.daemon_installer.run", fallback: "已安装并运行")
        }
        switch service.status {
        case .notRegistered:    return L10n.k("services.daemon_installer.not_installed", fallback: "未安装")
        case .enabled:          return L10n.k("services.daemon_installer.run", fallback: "已安装并运行")
        case .requiresApproval: return L10n.k("services.daemon_installer.waitinguser_settings", fallback: "等待用户授权（系统设置→登录项）")
        case .notFound:         return L10n.k("services.daemon_installer.app_bundle", fallback: "未找到（请检查 app bundle）")
        @unknown default:       return L10n.k("services.daemon_installer.unknownstatus", fallback: "未知状态")
        }
    }

    /// 注册 LaunchDaemon（首次调用会弹出系统授权对话框）
    /// 必须在主线程调用；DEBUG 模式下不操作
    func install() throws {
        guard !Self.isDevMode else { return }
        try service.register()
    }

    /// 注销 LaunchDaemon；DEBUG 模式下不操作
    func uninstall() throws {
        guard !Self.isDevMode else { return }
        try service.unregister()
    }

    /// 刷新状态（供强制 UI 刷新用）
    func refresh() {
        if Self.isDevMode { return }
        _ = service.status
    }

    /// 强制重启 Helper（通过 launchctl kickstart -k，需要管理员密码授权）
    /// 适用于 Helper 卡死、XPC 无响应等场景
    @discardableResult
    func forceRestart() -> Bool {
        let script = """
        do shell script "launchctl kickstart -k system/ai.clawdhome.mac.helper" with administrator privileges
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? L10n.k("services.daemon_installer.unknown_error", fallback: "未知错误")
            os_log(.error, "[DaemonInstaller] forceRestart failed: %{public}@", msg)
            return false
        }
        os_log(.info, "[DaemonInstaller] forceRestart succeeded via launchctl kickstart -k")
        return true
    }
}
