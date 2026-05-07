// ClawdHome/Views/AppUpdateBanner.swift
// 侧边栏底部的 App 更新提示横幅 + 更新详情 Sheet

import AppKit
import SwiftUI

// MARK: - 侧边栏横幅

struct AppUpdateBanner: View {
    @Environment(UpdateChecker.self) private var updater
    @State private var showSheet = false

    var body: some View {
        if updater.appNeedsUpdate || updater.isAwaitingAppRelaunch {
            Group {
                if updater.isAwaitingAppRelaunch {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.k("auto.app_update_banner.installing_title", fallback: "安装器已启动"))
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(L10n.k("auto.app_update_banner.installing_subtitle", fallback: "完成安装后会自动重启"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Button { showSheet = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 15))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L10n.k("auto.app_update_banner.new_version_available", fallback: "有新版本"))
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("v\(updater.appLatestVersion ?? "")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .sheet(isPresented: $showSheet) {
                AppUpdateSheet()
                    .environment(updater)
            }
        }
    }
}

// MARK: - 更新详情 Sheet

struct AppUpdateSheet: View {
    @Environment(UpdateChecker.self) private var updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("auto.app_update_banner.clawdhome_version", fallback: "ClawdHome 有新版本"))
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text("v\(updater.currentAppVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("v\(updater.appLatestVersion ?? "")")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            .padding(.bottom, 16)

            Divider()
                .padding(.bottom, 12)

            // 更新说明
            if let notes = updater.appReleaseNotes {
                Text(L10n.k("auto.app_update_banner.release_notes", fallback: "更新内容"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                ScrollView {
                    Text(notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                .padding(.bottom, 16)
            }

            // 进度条 / 按钮区
            if updater.isAwaitingAppRelaunch {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.orange)
                    Text(L10n.k("auto.app_update_banner.waiting_for_install", fallback: "安装器已打开。完成安装后，ClawdHome 会自动重新打开。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
            } else if let progress = updater.appUpdateProgress {
                VStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.orange)
                    if progress < 1.0 {
                        HStack(spacing: 0) {
                            // 左侧：百分比 + 大小
                            let pct = "\(Int(progress * 100))%"
                            let size = updater.appTotalBytes > 0
                                ? " · \(UpdateChecker.formatBytes(updater.appDownloadedBytes)) / \(UpdateChecker.formatBytes(updater.appTotalBytes))"
                                : ""
                            let speed = updater.appDownloadSpeed > 0
                                ? " · \(UpdateChecker.formatSpeed(updater.appDownloadSpeed))"
                                : ""
                            Text(L10n.f("views.app_update_banner.text_ee19e45e", fallback: "正在下载 %@%@%@", String(describing: pct), String(describing: size), String(describing: speed)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            // 取消按钮
                            Button {
                                updater.cancelDownload()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .help(L10n.k("auto.app_update_banner.cancel_download", fallback: "取消下载"))
                        }
                    } else {
                        Text(L10n.k("auto.app_update_banner.open", fallback: "即将打开安装程序..."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.top, 4)
            } else {
                // 错误信息
                if let err = updater.appUpdateError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    .padding(.bottom, 8)
                }

                HStack {
                    Spacer()
                    Button(L10n.k("auto.app_update_banner.later", fallback: "稍后再说")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(updater.appUpdateError != nil ? L10n.k("views.app_update_banner.retry", fallback: "重试") : L10n.k("views.app_update_banner.update_now", fallback: "立即更新")) {
                        Task { await updater.downloadAndInstall() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .onChange(of: updater.isAwaitingAppRelaunch) { _, waiting in
            if waiting { dismiss() }
        }
    }
}
