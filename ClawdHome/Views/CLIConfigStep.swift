// ClawdHome/Views/CLIConfigStep.swift
// 通用 CLI 配置入口：Terminal 为主，UI 向导为备选（标注实验性）

import SwiftUI

struct CLIConfigStep: View {
    let user: ManagedUser
    /// Terminal 里实际执行的命令，如 "sudo su - jerry -c 'openclaw onboard'"
    let terminalCommand: String
    /// 用户确认完成时回调
    var onDone: (() -> Void)?

    @State private var terminalOpened = false
    @State private var showUIFallback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showUIFallback {
                uiFallbackView
            } else if terminalOpened {
                waitingView
            } else {
                initialView
            }
        }
    }

    // MARK: - 初始状态（未打开过终端）
    private var initialView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.k("views.cliconfig_step.configuration_openclaw", fallback: "配置 openclaw"), systemImage: "terminal")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Button {
                if openTerminal() {
                    terminalOpened = true
                }
            } label: {
                Label(L10n.k("views.cliconfig_step.configuration", fallback: "在终端配置（推荐）"), systemImage: "apple.terminal")
            }
            .buttonStyle(.borderedProminent)

            Button(L10n.k("views.cliconfig_step.configuration_2525b2", fallback: "在此配置（实验性）")) {
                showUIFallback = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .font(.callout)
        }
    }

    // MARK: - 等待用户在终端完成
    private var waitingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "apple.terminal")
                    .foregroundStyle(.secondary)
                Text(L10n.k("views.cliconfig_step.done_configuration", fallback: "终端已打开，在终端完成配置后回到此处。"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(L10n.k("views.cliconfig_step.done_configuration_4880fd", fallback: "已完成配置")) {
                    onDone?()
                }
                .buttonStyle(.borderedProminent)

                Button(L10n.k("views.cliconfig_step.reopen_terminal", fallback: "重新打开终端")) {
                    openTerminal()
                }
                .buttonStyle(.bordered)
            }

            Divider()

            Button(L10n.k("views.cliconfig_step.configuration_5e18b6", fallback: "改用界面配置 ⚠️ 实验性")) {
                showUIFallback = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .font(.caption)
        }
    }

    // MARK: - UI 回退（ModelConfigWizard + 警告）
    private var uiFallbackView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.k("views.cliconfig_step.configuration_configuration", fallback: "界面配置功能尚不成熟，建议使用终端配置"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            ModelConfigWizard(user: user, embedded: true) {
                onDone?()
            }

            Button(L10n.k("views.cliconfig_step.back_to_terminal_entry", fallback: "返回终端入口")) {
                showUIFallback = false
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
    }

    // MARK: - 打开 Terminal.app
    @discardableResult
    private func openTerminal() -> Bool {
        let terminalTitle = L10n.f("views.cliconfig_step.terminal_title", fallback: "=== ClawdHome: 配置用户 %@ ===", user.username)
        let passwordHint = L10n.f("views.cliconfig_step.password_hint", fallback: "提示：接下来请输入 %@ 的 Mac 登录密码", NSUserName())
        let successLine = L10n.k("views.cliconfig_step.terminal_success", fallback: "配置完成。请返回 ClawdHome 点击「已完成配置」。")
        let failedLine = L10n.k("views.cliconfig_step.terminal_failed", fallback: "配置出现错误（退出码 $_exit），请检查输出并重试。")
        let closeHint = L10n.k("views.cliconfig_step.terminal_close_hint", fallback: "按 Return 键关闭此窗口...")

        let script = """
            #!/bin/bash
            clear
            echo "\(terminalTitle)"
            echo
            echo "\(passwordHint)"
            echo
            \(terminalCommand)
            _exit=$?
            echo
            if [ $_exit -eq 0 ]; then
                echo "\(successLine)"
            else
                echo "\(failedLine)"
            fi
            read -rp "\(closeHint)"
            """
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawd-config-\(user.username).command")
        do {
            try script.write(to: tmpURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tmpURL.path)
            NSWorkspace.shared.open(tmpURL)
            return true
        } catch {
            return false
        }
    }
}
