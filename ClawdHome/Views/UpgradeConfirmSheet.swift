// ClawdHome/Views/UpgradeConfirmSheet.swift
// 升级确认 Sheet：显示版本信息、Release Notes 链接、备份开关

import SwiftUI

struct UpgradeConfirmSheet: View {
    let username: String
    let currentVersion: String?
    let targetVersion: String
    let releaseURL: URL?
    let isInstalling: Bool
    let installError: String?
    /// 确认回调：(version, shouldBackup)
    var onConfirm: (_ version: String, _ backup: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 持久化备份偏好（默认开）
    @AppStorage("upgradeAutoBackup") private var autoBackup = true
    @State private var upgradeRequested = false

    private var canClose: Bool { !isInstalling }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.green)
                Text(L10n.k("auto.upgrade_confirm_sheet.upgrade_openclaw", fallback: "升级 openclaw")).font(.headline)
                Spacer()
                Button(L10n.k("auto.upgrade_confirm_sheet.cancel", fallback: "取消")) { dismiss() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!canClose)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // 版本信息
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text(L10n.k("auto.upgrade_confirm_sheet.current_version", fallback: "当前版本")).foregroundStyle(.secondary)
                        Text(currentVersion ?? L10n.k("auto.upgrade_confirm_sheet.unknown", fallback: "未知")).monospacedDigit()
                    }
                    GridRow {
                        Text(L10n.k("auto.upgrade_confirm_sheet.latest_version", fallback: "最新版本")).foregroundStyle(.secondary)
                        Text(targetVersion)
                            .monospacedDigit()
                            .foregroundStyle(.green)
                            .fontWeight(.medium)
                    }
                    GridRow {
                        Text(L10n.k("auto.upgrade_confirm_sheet.user", fallback: "用户")).foregroundStyle(.secondary)
                        Text("@\(username)")
                    }
                }

                Divider()

                // 备份开关
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L10n.k("auto.upgrade_confirm_sheet.upgradebackupconfiguration", fallback: "升级前自动备份配置"), isOn: $autoBackup)

                    if autoBackup {
                        Text(L10n.k("auto.upgrade_confirm_sheet.documents_clawdhome_backups_savebackup_upgraderollback", fallback: "将在 ~/Documents/ClawdHome Backups/ 保存一份备份，升级后可一键回退。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.k("auto.upgrade_confirm_sheet.backuprollback_saveconfiguration", fallback: "不备份则无法回退，请确认已手动保存重要配置。"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Text(L10n.k("auto.upgrade_confirm_sheet.upgrade_gateway_stop", fallback: "升级期间 Gateway 将暂时停止。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .padding(.top, 1)
                    Text(L10n.k("auto.upgrade_confirm_sheet.wait_and_watch_warning", fallback: "风险提示：不要盲目升级新版本，建议先观望几天，确认社区反馈稳定后再升级。"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if isInstalling || upgradeRequested {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if isInstalling {
                        Label(L10n.k("upgrade.confirm.status.installing", fallback: "升级中…"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.medium))
                    } else if let installError, !installError.isEmpty {
                        Label(L10n.k("upgrade.confirm.status.failed", fallback: "升级失败"), systemImage: "xmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                        Text(installError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else {
                        Label(L10n.k("upgrade.confirm.status.done", fallback: "升级完成"), systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    TerminalLogPanel(username: username)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }

            Divider()

            // 底部操作栏
            HStack {
                if let url = releaseURL {
                    Button(L10n.k("auto.upgrade_confirm_sheet.view_release_notes", fallback: "查看更新内容")) {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                Spacer()
                Button(upgradeRequested ? L10n.k("auto.upgrade_confirm_sheet.done", fallback: "完成") : L10n.k("auto.upgrade_confirm_sheet.cancel", fallback: "取消")) { dismiss() }
                    .buttonStyle(.bordered)
                    .disabled(!canClose)
                if !upgradeRequested || (upgradeRequested && !isInstalling && (installError?.isEmpty == false)) {
                    Button(isInstalling ? L10n.k("auto.upgrade_confirm_sheet.text_5fc65af5b3", fallback: "处理中…") : L10n.k("auto.upgrade_confirm_sheet.upgrade", fallback: "升级")) {
                        let shouldBackup = autoBackup
                        upgradeRequested = true
                        onConfirm(targetVersion, shouldBackup)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(isInstalling)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560)
    }
}
