import SwiftUI

struct HostPermissionBanner: View {
    @Environment(HostPermissionCenter.self) private var permissionCenter

    var body: some View {
        if permissionCenter.hasIssues {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 20, height: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.k("host_permission.banner.title", zh: "需要系统权限授权", en: "Permission needed"))
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(summaryText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if permissionCenter.accessibilityMissing {
                    Button(L10n.k("host_permission.banner.action.accessibility", zh: "授权辅助功能", en: "UI Access")) {
                        permissionCenter.requestAccessibilityPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if permissionCenter.chromeAutomationMissing {
                    Button(L10n.k("host_permission.banner.action.chrome_automation", zh: "授权 Chrome 自动化", en: "Enable Chrome")) {
                        permissionCenter.requestChromeAutomationPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        secondaryActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        secondaryActions
                    }
                }
            }
            .padding(10)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.orange.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private var summaryText: String {
        var parts: [String] = []
        if permissionCenter.accessibilityMissing {
            parts.append(L10n.k("host_permission.banner.missing.accessibility", zh: "辅助功能（UI 自动化）", en: "Accessibility (UI automation)"))
        }
        if permissionCenter.chromeAutomationMissing {
            switch permissionCenter.chromeAutomationStatus {
            case .requiresConsent:
                parts.append(L10n.k("host_permission.banner.missing.chrome_pending", zh: "Chrome 自动化（待同意）", en: "Chrome automation (pending consent)"))
            case .denied:
                parts.append(L10n.k("host_permission.banner.missing.chrome_denied", zh: "Chrome 自动化（已拒绝）", en: "Chrome automation (denied)"))
            case .unavailable:
                parts.append(L10n.k("host_permission.banner.missing.chrome_unavailable", zh: "Chrome 自动化（不可用）", en: "Chrome automation (unavailable)"))
            case .granted:
                break
            }
        }
        if parts.isEmpty {
            return L10n.k("host_permission.banner.summary.ready", zh: "所有必需权限已就绪", en: "All required permissions are ready")
        }
        let selected = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        let isChineseUI: Bool
        switch AppLanguage(rawValue: selected) ?? .system {
        case .chineseSimplified:
            isChineseUI = true
        case .english:
            isChineseUI = false
        case .system:
            isChineseUI = (Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false)
        }
        let separator = isChineseUI ? "、" : ", "
        return L10n.f("host_permission.banner.summary.missing", zh: "缺失权限：%@。授权后可自动执行浏览器相关操作。", en: "Missing: %@. Grant access for browser automation.", parts.joined(separator: separator))
    }

    @ViewBuilder
    private var secondaryActions: some View {
        Button(L10n.k("host_permission.banner.action.open_settings", zh: "打开系统设置", en: "Open Settings")) {
            if permissionCenter.accessibilityMissing {
                permissionCenter.openAccessibilitySettings()
            } else if permissionCenter.chromeAutomationMissing {
                permissionCenter.openAutomationSettings()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button(L10n.k("host_permission.banner.action.refresh", zh: "刷新", en: "Refresh")) {
            permissionCenter.refresh()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
