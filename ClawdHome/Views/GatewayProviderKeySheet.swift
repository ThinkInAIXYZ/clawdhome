// ClawdHome/Views/GatewayProviderKeySheet.swift
// 设置单个 AI Provider 的 API Key 或服务地址（通过 Gateway WebSocket 写入）

import SwiftUI

struct GatewayProviderKeySheet: View {
    let username: String
    let config: ProviderKeyConfig
    /// 是否已配置（__OPENCLAW_REDACTED__ 返回 true）
    let isConfigured: Bool
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(GatewayHub.self) private var gatewayHub

    @State private var input: String = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showClearConfirm = false

    private var trimmed: String { input.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { !trimmed.isEmpty && trimmed != "•••••••••••••" }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(isConfigured ? "更换 \(config.displayName) \(config.inputLabel)" : "设置 \(config.displayName) \(config.inputLabel)")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.escape)
                Button(isSaving ? "保存中…" : "保存") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(!canSave || isSaving)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // 当前状态提示
                HStack(spacing: 6) {
                    Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(isConfigured ? .green : .secondary)
                        .font(.system(size: 12))
                    Text(isConfigured ? "当前已配置（内容已脱敏）" : "尚未配置")
                        .font(.caption)
                        .foregroundStyle(isConfigured ? .green : .secondary)
                }

                // 输入框
                VStack(alignment: .leading, spacing: 6) {
                    Text(config.inputLabel)
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    if config.isUrlConfig {
                        TextField(config.placeholder, text: $input)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField(config.placeholder, text: $input)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    Text("配置路径：\(config.configPath)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // 错误提示
                if let err = saveError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }

                // 清除按钮（已配置时显示）
                if isConfigured {
                    Divider()
                    HStack {
                        Button("清除配置", role: .destructive) {
                            showClearConfirm = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.callout)
                        Spacer()
                        Text("清除后 \(config.displayName) 将不可用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(20)
        }
        .frame(width: 420, height: isConfigured ? 300 : 260)
        .alert("清除 \(config.displayName) \(config.inputLabel)？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) { }
            Button("清除", role: .destructive) {
                Task { await clear() }
            }
        } message: {
            Text("清除后该 Provider 将无法使用，需要重新配置才能恢复。")
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        do {
            try await gatewayHub.configSet(username: username, path: config.configPath, value: trimmed)
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }

    private func clear() async {
        isSaving = true
        saveError = nil
        do {
            // 写入空字符串等价于清除（openclaw 会删除该字段）
            try await gatewayHub.configSet(username: username, path: config.configPath, value: "")
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }
}
