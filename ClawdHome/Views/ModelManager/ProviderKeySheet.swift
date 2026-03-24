import SwiftUI

struct ProviderKeySheet: View {
    let provider: KnownProvider
    @Environment(\.dismiss) private var dismiss
    @Environment(ProviderKeychainStore.self) private var keychainStore
    @State private var apiKey: String = ""
    @State private var showKey = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(provider.displayName) API Key").font(.headline)
                Spacer()
                Button(L10n.k("views.model_manager.provider_key_sheet.cancel", fallback: "取消")) { dismiss() }.keyboardShortcut(.escape)
                Button(L10n.k("views.model_manager.provider_key_sheet.save", fallback: "保存")) {
                    let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { keychainStore.delete(for: provider) }
                    else { keychainStore.save(apiKey: trimmed, for: provider) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
            .padding()
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if showKey {
                    TextField(provider.keyPlaceholder, text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    SecureField(provider.keyPlaceholder, text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle(L10n.k("views.model_manager.provider_key_sheet.show_plain_text", fallback: "显示明文"), isOn: $showKey)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if keychainStore.hasKey(for: provider) {
                    Button(L10n.k("views.model_manager.provider_key_sheet.save_key", fallback: "清除已保存的 Key"), role: .destructive) {
                        keychainStore.delete(for: provider)
                        apiKey = ""
                        dismiss()
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .frame(width: 400)
    }
}
