import SwiftUI

struct HostPermissionBanner: View {
    @Environment(HostPermissionCenter.self) private var permissionCenter

    private let bannerBackground = Color(red: 0.99, green: 0.95, blue: 0.90)

    var body: some View {
        if permissionCenter.hasIssues {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.k("host_permission.banner.title", fallback: "需要系统权限授权"))
                        .fontWeight(.medium)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    if permissionCenter.accessibilityMissing {
                        Button(L10n.k("host_permission.banner.action.accessibility", fallback: "授权辅助功能")) {
                            permissionCenter.requestAccessibilityPermission()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if permissionCenter.chromeAutomationMissing {
                        Button(L10n.k("host_permission.banner.action.chrome_automation", fallback: "授权 Chrome 自动化")) {
                            permissionCenter.requestChromeAutomationPermission()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button(L10n.k("host_permission.banner.action.open_settings", fallback: "打开系统设置")) {
                        if permissionCenter.accessibilityMissing {
                            permissionCenter.openAccessibilitySettings()
                        } else if permissionCenter.chromeAutomationMissing {
                            permissionCenter.openAutomationSettings()
                        }
                    }
                    .buttonStyle(.bordered)

                    Button(L10n.k("host_permission.banner.action.refresh", fallback: "刷新")) {
                        permissionCenter.refresh()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(bannerBackground)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var summaryText: String {
        var parts: [String] = []
        if permissionCenter.accessibilityMissing {
            parts.append(L10n.k("host_permission.banner.missing.accessibility", fallback: "辅助功能（UI 自动化）"))
        }
        if permissionCenter.chromeAutomationMissing {
            switch permissionCenter.chromeAutomationStatus {
            case .requiresConsent:
                parts.append(L10n.k("host_permission.banner.missing.chrome_pending", fallback: "Chrome 自动化（待同意）"))
            case .denied:
                parts.append(L10n.k("host_permission.banner.missing.chrome_denied", fallback: "Chrome 自动化（已拒绝）"))
            case .unavailable:
                parts.append(L10n.k("host_permission.banner.missing.chrome_unavailable", fallback: "Chrome 自动化（不可用）"))
            case .granted:
                break
            }
        }
        if parts.isEmpty {
            return L10n.k("host_permission.banner.summary.ready", fallback: "所有必需权限已就绪")
        }
        return L10n.f(
            "host_permission.banner.summary.missing",
            fallback: "缺失权限：%@。授权后可自动执行浏览器相关操作。",
            parts.joined(separator: "、")
        )
    }
}
