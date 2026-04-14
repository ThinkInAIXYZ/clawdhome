// ClawdHome/Views/DaemonSetupBanner.swift

import SwiftUI
import ServiceManagement

struct DaemonSetupBanner: View {
    let installer: DaemonInstaller
    @Environment(HelperClient.self) private var helperClient
    @State private var isInstalling = false
    @State private var isRestarting = false
    @State private var errorMessage: String?
    private let bannerBackground = Color(red: 0.99, green: 0.95, blue: 0.90)

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.k("auto.daemon_setup_banner.clawdhome_user", fallback: "ClawdHome 需要安装系统服务才能管理用户"))
                    .fontWeight(.medium)
                Text(installer.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            if installer.status == .requiresApproval {
                Button(L10n.k("auto.daemon_setup_banner.opensettings", fallback: "打开系统设置")) {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(.bordered)
            } else {
                // 已安装但无法连接 → 提供重启选项
                if installer.isEnabled {
                    Button {
                        Task { await forceRestart() }
                    } label: {
                        HStack(spacing: 4) {
                            if isRestarting {
                                ProgressView().controlSize(.small)
                            }
                            Text(isRestarting ? L10n.k("views.daemon_setup.restarting", fallback: "重启中…") : L10n.k("views.daemon_setup.restart_helper", fallback: "重启 Helper"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isRestarting)
                } else {
                    Button(isInstalling ? L10n.k("auto.daemon_setup_banner.text_b2c6913616", fallback: "安装中…") : L10n.k("auto.daemon_setup_banner.install", fallback: "安装")) {
                        Task { await install() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(bannerBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func install() async {
        isInstalling = true
        errorMessage = nil
        do {
            try installer.install()
        } catch {
            errorMessage = error.localizedDescription
        }
        isInstalling = false
    }

    private func forceRestart() async {
        isRestarting = true
        errorMessage = nil

        // 先尝试 XPC 优雅重启
        let graceful = await helperClient.requestHelperRestart()
        if graceful {
            try? await Task.sleep(for: .seconds(2))
            helperClient.connect()
            try? await Task.sleep(for: .seconds(1))
            isRestarting = false
            return
        }

        // XPC 不通 → launchctl 强制重启（弹出管理员密码授权）
        let ok = installer.forceRestart()
        if ok {
            try? await Task.sleep(for: .seconds(2))
            helperClient.connect()
        } else {
            errorMessage = L10n.k("views.daemon_setup.restart_failed", fallback: "重启失败，请手动运行：sudo launchctl kickstart -k system/ai.clawdhome.mac.helper")
        }
        isRestarting = false
    }
}
