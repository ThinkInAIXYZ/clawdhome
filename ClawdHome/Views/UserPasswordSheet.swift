// ClawdHome/Views/UserPasswordSheet.swift

import AppKit
import Carbon.HIToolbox
import SwiftUI

enum KeyboardInputSourceSwitcher {
    static func switchToEnglishASCII() {
        guard let source = preferredEnglishSource() ?? fallbackASCIISource() else { return }
        TISSelectInputSource(source)
    }

    private static func preferredEnglishSource() -> TISInputSource? {
        allKeyboardInputSources().first {
            guard tisProperty($0, kTISPropertyInputSourceIsASCIICapable, as: Bool.self) == true else {
                return false
            }
            let languages = tisProperty($0, kTISPropertyInputSourceLanguages, as: [String].self) ?? []
            return languages.contains { $0.hasPrefix("en") }
        }
    }

    private static func fallbackASCIISource() -> TISInputSource? {
        allKeyboardInputSources().first {
            tisProperty($0, kTISPropertyInputSourceIsASCIICapable, as: Bool.self) == true
        }
    }

    private static func allKeyboardInputSources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        return TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
    }

    private static func tisProperty<T>(_ source: TISInputSource, _ key: CFString, as type: T.Type) -> T? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        return value as? T
    }
}

// MARK: - 查看用户密码 Sheet

struct UserPasswordSheet: View {
    let username: String
    @Environment(\.dismiss) private var dismiss
    @Environment(HelperClient.self) private var helperClient
    @State private var isRevealed = false
    @State private var storedPassword: String? = nil
    @State private var isResetting = false
    @State private var resetError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.f("views.user_detail_view.text_82ba9ab1", fallback: "@%@ 的登录密码", String(describing: username)))
                .font(.title3)
                .fontWeight(.semibold)

            if let pw = storedPassword {
                GroupBox {
                    HStack {
                        if isRevealed {
                            Text(pw)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Text(String(repeating: "•", count: pw.count))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pw, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L10n.k("user.detail.auto.password", fallback: "复制密码"))

                        Button { isRevealed.toggle() } label: {
                            Image(systemName: isRevealed ? "eye.slash" : "eye").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(isRevealed ? L10n.k("user.detail.auto.password", fallback: "隐藏密码") : L10n.k("user.detail.auto.password", fallback: "显示密码"))
                    }
                    .padding(4)
                }
            } else {
                GroupBox {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.k("user.detail.auto.password", fallback: "未找到已存储的密码"))
                                .fontWeight(.medium)
                            Text(L10n.k("user.detail.auto.userpassword_resetpassword", fallback: "该用户可能在密码管理功能上线前创建，点击下方按钮重置密码"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }
                Button(isResetting ? L10n.k("user.detail.auto.reset", fallback: "重置中…") : L10n.k("user.detail.auto.passwordreset", fallback: "生成新密码并重置")) {
                    Task { await resetPassword() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResetting || !helperClient.isConnected)
                if let err = resetError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Text(L10n.k("user.detail.auto.passworduser", fallback: "此密码用于该用户登录图形界面"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if storedPassword != nil {
                    Button(isResetting ? L10n.k("user.detail.auto.reset", fallback: "重置中…") : L10n.k("user.detail.auto.resetpassword", fallback: "重置密码")) {
                        Task { await resetPassword() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isResetting || !helperClient.isConnected)
                }
                Spacer()
                Button(L10n.k("user.detail.auto.close", fallback: "关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            do {
                storedPassword = try UserPasswordStore.load(for: username)
            } catch {
                storedPassword = nil
                resetError = error.localizedDescription
            }
        }
    }

    private func resetPassword() async {
        isResetting = true
        resetError = nil
        do {
            let newPw = try UserPasswordStore.generateAndSave(for: username)
            do {
                try await helperClient.changeUserPassword(username: username, newPassword: newPw)
                storedPassword = newPw
                isRevealed = true  // 重置后自动显示，方便用户确认
            } catch {
                // 回滚 Keychain（避免存入的密码与实际账户密码不一致）
                UserPasswordStore.delete(for: username)
                storedPassword = nil
                resetError = error.localizedDescription
            }
        } catch {
            resetError = error.localizedDescription
        }
        isResetting = false
    }
}
