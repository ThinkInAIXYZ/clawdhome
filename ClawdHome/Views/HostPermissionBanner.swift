import SwiftUI

struct HostPermissionPromptRequest: Identifiable, Equatable {
    let id = UUID()
    let actionLabel: String
    let missingPermissions: [HostPermissionRequirement]
}

extension View {
    func hostPermissionPrompt(
        _ request: Binding<HostPermissionPromptRequest?>
    ) -> some View {
        modifier(HostPermissionPromptModifier(request: request))
    }
}

private struct HostPermissionPromptModifier: ViewModifier {
    @Environment(HostPermissionCenter.self) private var permissionCenter
    @Binding var request: HostPermissionPromptRequest?

    func body(content: Content) -> some View {
        content.alert(
            request?.title ?? "",
            isPresented: isPresented,
            presenting: request
        ) { request in
            Button(L10n.k("host_permission.prompt.action.authorize_now", fallback: "继续授权")) {
                permissionCenter.requestBrowserAutomationPermissions(request.missingPermissions)
                self.request = nil
            }
            Button(L10n.k("host_permission.banner.action.open_settings", fallback: "打开系统设置")) {
                permissionCenter.openSettings(for: request.missingPermissions)
                self.request = nil
            }
            Button(L10n.k("common.action.cancel", fallback: "取消"), role: .cancel) {
                self.request = nil
            }
        } message: { request in
            Text(request.message)
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { request != nil },
            set: {
                if !$0 {
                    request = nil
                }
            }
        )
    }
}

private extension HostPermissionPromptRequest {
    var title: String {
        L10n.k("host_permission.banner.title", fallback: "需要系统权限授权")
    }

    var message: String {
        L10n.f(
            "host_permission.prompt.message",
            fallback: "执行“%@”前，需要先授权：%@。你也可以稍后去设置里手动授权，完成后再重试。",
            actionLabel,
            missingPermissionsText
        )
    }

    var missingPermissionsText: String {
        let separator = Self.isChineseUI ? "、" : ", "
        return missingPermissions
            .map(\.displayName)
            .joined(separator: separator)
    }

    static var isChineseUI: Bool {
        let selected = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        switch AppLanguage(rawValue: selected) ?? .system {
        case .chineseSimplified:
            return true
        case .english:
            return false
        case .system:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        }
    }
}

private extension HostPermissionRequirement {
    var displayName: String {
        switch self {
        case .accessibility:
            return L10n.k("settings.permissions.accessibility", fallback: "辅助功能")
        case .chromeAutomation:
            return L10n.k("settings.permissions.chrome_automation", fallback: "Chrome 自动化")
        }
    }
}

// 兼容现有工程文件引用；首页常驻权限浮层已停用。
struct HostPermissionBanner: View {
    var body: some View {
        EmptyView()
    }
}
