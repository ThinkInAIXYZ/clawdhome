// ClawdHome/Views/AppLockScreen.swift
// 锁屏界面：密码解锁 + Touch ID 解锁

import SwiftUI

struct AppLockScreen: View {
    @Environment(AppLockStore.self) private var lockStore

    @State private var password = ""
    @State private var unlockError: UnlockError? = nil
    @FocusState private var focused: Bool

    enum UnlockError {
        case wrongPassword
        case keychainDenied
    }

    var body: some View {
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text("ClawdHome 已锁定")
                        .font(.title2.weight(.semibold))
                    Text("请输入管理密码以继续")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    SecureField("管理密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .focused($focused)
                        .onSubmit { tryUnlock() }

                    // 错误提示
                    if let err = unlockError {
                        Group {
                            switch err {
                            case .wrongPassword:
                                Label("密码错误，请重试", systemImage: "xmark.circle.fill")
                            case .keychainDenied:
                                VStack(spacing: 4) {
                                    Label("Keychain 访问被拒绝", systemImage: "exclamationmark.lock.fill")
                                        .fontWeight(.medium)
                                    Text("请在系统弹窗中点击\"允许\"，或前往\n钥匙串访问手动授权 ClawdHome")
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }

                    Button("解锁") { tryUnlock() }
                        .buttonStyle(.borderedProminent)
                        .disabled(password.isEmpty)
                }

                if lockStore.isBiometricEnabled && lockStore.isBiometricAvailable {
                    Button {
                        Task { await lockStore.unlockWithBiometrics() }
                    } label: {
                        Label("使用 Touch ID 解锁", systemImage: "touchid")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                Spacer()
            }
            .padding(40)
        }
        .onAppear {
            focused = true
            if lockStore.isBiometricEnabled && lockStore.isBiometricAvailable {
                Task { await lockStore.unlockWithBiometrics() }
            }
        }
    }

    private func tryUnlock() {
        let result = lockStore.unlockWithPassword(password)
        password = ""
        switch result {
        case .success:
            unlockError = nil
        case .wrongPassword:
            unlockError = .wrongPassword
        case .keychainDenied:
            unlockError = .keychainDenied
        }
    }
}

// MARK: - 毛玻璃背景

private struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
