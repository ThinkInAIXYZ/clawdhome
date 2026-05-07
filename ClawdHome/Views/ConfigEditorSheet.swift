// ClawdHome/Views/ConfigEditorSheet.swift
// openclaw 配置编辑表单
// 保存时调用 HelperClient.setConfig（XPC → ConfigWriter → sudo -u user openclaw config set）

import SwiftUI

struct ConfigEditorSheet: View {
    let user: ManagedUser

    @Environment(\.dismiss) private var dismiss
    @Environment(HelperClient.self) private var helperClient

    // 预设配置字段
    @State private var apiKey: String = ""
    @State private var gatewayMode: String = "local"
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveSuccess = false

    private let gatewayModes = ["local", "remote"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.f("views.config_editor_sheet.text_873f12d4", fallback: "配置 — @%@", String(describing: user.username)))
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.bottom, 16)

            Form {
                Section {
                    SecureField("Anthropic API Key（sk-ant-…）", text: $apiKey)
                        .textContentType(.password)
                    Text(L10n.k("views.config_editor_sheet.claude_api", fallback: "用于访问 Claude API。留空则保持现有值不变。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("API Key")
                }

                Section {
                    Picker(L10n.k("views.config_editor_sheet.text_44c4aaa1", fallback: "运行模式"), selection: $gatewayMode) {
                        ForEach(gatewayModes, id: \.self) { mode in
                            Text(mode).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(L10n.k("views.config_editor_sheet.gateway", fallback: "Gateway 模式"))
                } footer: {
                    Text(L10n.k("views.config_editor_sheet.local", fallback: "local：在本机运行（推荐家庭使用）"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }

            if saveSuccess {
                Label(L10n.k("views.config_editor_sheet.configuration_save", fallback: "配置已保存"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .padding(.top, 4)
            }

            HStack {
                Spacer()
                Button(L10n.k("views.config_editor_sheet.cancel", fallback: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? L10n.k("views.config_editor_sheet.save", fallback: "保存中…") : L10n.k("views.config_editor_sheet.save_be5fbb", fallback: "保存")) {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 460)
    }

    private func save() async {
        isSaving = true
        saveError = nil
        saveSuccess = false

        do {
            // 只保存非空字段
            if !apiKey.isEmpty {
                try await helperClient.setConfig(username: user.username, key: "anthropic.apiKey", value: apiKey)
            }
            try await helperClient.setConfig(username: user.username, key: "gateway.mode", value: gatewayMode)
            saveSuccess = true
            // 短暂显示成功后关闭
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }
}
