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
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var hermesVersion: String?
    @State private var isInstalling = false
    @State private var installError: String?
    @State private var installDone = false
    @State private var hermesRunning = false
    @State private var hermesPID: Int32 = -1
    @State private var isStarting = false
    @State private var isStopping = false

    private var isInstalled: Bool { hermesVersion != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusSection
                    if isInstalled {
                        gatewaySection
                        terminalSection
                    } else {
                        installSection
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task { await refreshStatus() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(.purple)
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
                        Text("未安装")
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
            Text("Hermes 状态")
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - 安装

    private var installSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hermes Agent 是一个自进化 AI 代理框架，支持 20+ 消息平台，需要 Python 3.11+。")
                    .font(.callout)
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
                        Task { await performInstall() }
                    } label: {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                            Text("安装中…")
                        } else {
                            Label("安装 Hermes Agent", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(isInstalling)
                }
            }
        } label: {
            Text("安装")
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Gateway 控制

    private var gatewaySection: some View {
        GroupBox {
            HStack(spacing: 12) {
                Button {
                    Task { await startHermes() }
                } label: {
                    Label("启动", systemImage: "play.fill")
                }
                .disabled(hermesRunning || isStarting || isStopping)

                Button {
                    Task { await stopHermes() }
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(!hermesRunning || isStarting || isStopping)

                if isStarting || isStopping {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button {
                    Task { await refreshStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新状态")
            }
        } label: {
            Text("Gateway 控制")
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - 维护终端

    private var terminalSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("在维护终端中使用 Hermes CLI（独立环境，不含 Node.js/npm）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Hermes Shell") {
                        openHermesTerminal(["hermes"])
                    }
                    Button("hermes setup") {
                        openHermesTerminal(["hermes", "setup"])
                    }
                    Button("hermes status") {
                        openHermesTerminal(["hermes", "gateway", "--status"])
                    }
                    Spacer()
                }
            }
        } label: {
            Text("维护终端")
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

    private func startHermes() async {
        isStarting = true
        do {
            try await helperClient.startHermesGateway(username: user.username)
        } catch {
            installError = error.localizedDescription
        }
        try? await Task.sleep(for: .seconds(1))
        await refreshStatus()
        isStarting = false
    }

    private func stopHermes() async {
        isStopping = true
        do {
            try await helperClient.stopHermesGateway(username: user.username)
        } catch {
            installError = error.localizedDescription
        }
        try? await Task.sleep(for: .seconds(0.5))
        await refreshStatus()
        isStopping = false
    }

    private func openHermesTerminal(_ command: [String]) {
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: "Hermes · @\(user.username)",
            command: command
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }
}
