// ClawdHome/Views/HermesSetupSheet.swift
// Hermes Agent 独立安装与管理面板
//
// 设计：与 OpenClaw 安装流程完全分离，步骤不同。
// 当前最小步骤：检测 Python → 安装 Hermes → 完成。
// 不含频道绑定、模型配置（由后续版本或维护终端处理）。

import SwiftUI

struct HermesSetupSheet: View {
    let user: ManagedUser

    @Environment(HelperClient.self) private var helperClient
    @Environment(\.dismiss) private var dismiss

    @State private var hermesVersion: String?
    @State private var isInstalling = false
    @State private var installTask: Task<Void, Never>?
    @State private var installError: String?
    @State private var installDone = false
    @State private var hermesRunning = false
    @State private var hermesPID: Int32 = -1

    private var isInstalled: Bool { hermesVersion != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusSection
                    if isInstalled {
                        installedHintSection
                    } else {
                        installSection
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task { await refreshStatus() }
        .onDisappear {
            if isInstalling {
                installTask?.cancel()
                Task {
                    await helperClient.cancelHermesInstall(username: user.username)
                }
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            HermesLogoMark()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hermes Agent")
                    .font(.headline)
                Text("@\(user.username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - 状态

    private var statusSection: some View {
        GroupBox {
            HStack {
                Label {
                    if let version = hermesVersion {
                        Text("v\(version)")
                    } else {
                        Text(L10n.k("hermes.setup.not_installed", fallback: "未安装"))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(isInstalled ? .green : .secondary)
                }
                Spacer()
                if isInstalled {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(hermesRunning ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(hermesRunning ? "运行中 (PID \(hermesPID))" : "已停止")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            Text(L10n.k("hermes.setup.status_title", fallback: "Hermes 状态"))
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - 安装

    private var installSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.k("hermes.setup.description", fallback: "Hermes Agent 是一个自进化 AI 代理框架，支持 20+ 消息平台，需要 Python 3.11+。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(L10n.k("hermes.setup.install_steps", fallback: "安装步骤：1) 修复 Homebrew 权限  2) 安装 Hermes Agent"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = installError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                HStack {
                    Spacer()
                    Button {
                        installTask = Task { await performInstall() }
                    } label: {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                            Text(L10n.k("hermes.setup.installing", fallback: "安装中…"))
                        } else {
                            Label(L10n.k("hermes.setup.install_action", fallback: "安装 Hermes Agent"), systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(isInstalling)
                }
            }
        } label: {
            Text(L10n.k("hermes.setup.install_button", fallback: "安装"))
            .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - 已安装提示

    private var installedHintSection: some View {
        GroupBox {
            if installDone {
                Label(L10n.k("hermes.setup.install_done", fallback: "安装完成"), systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Text(L10n.k("hermes.setup.installed_hint", fallback: "Hermes Agent 已安装。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(L10n.k("common.status.installed", fallback: "已安装"))
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Actions

    private func refreshStatus() async {
        hermesVersion = await helperClient.getHermesVersion(username: user.username)
        let status = await helperClient.getHermesGatewayStatus(username: user.username)
        hermesRunning = status.running
        hermesPID = status.pid
    }

    private func performInstall() async {
        isInstalling = true
        installError = nil
        do {
            try await helperClient.installHermes(username: user.username)
            installDone = true
            await refreshStatus()
        } catch {
            installError = error.localizedDescription
        }
        isInstalling = false
    }
}
