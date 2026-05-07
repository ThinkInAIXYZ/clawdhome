// ClawdHome/Views/AddUserSheet.swift

import SwiftUI

struct AddUserSheet: View {
    /// (username, fullName, password)
    let onConfirm: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var fullName = ""
    @State private var password = ""
    @State private var confirmPassword = ""

    /// macOS 短用户名规则：小写字母/数字/下划线，1-32 位
    private var usernameValid: Bool {
        username.range(of: #"^[a-z_][a-z0-9_]{0,31}$"#, options: .regularExpression) != nil
    }

    private var isValid: Bool {
        usernameValid && !password.isEmpty && password == confirmPassword
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.k("user.add.sheet.title", fallback: "添加用户"))
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.bottom, 16)

            Form {
                Section {
                    TextField(L10n.k("user.add.form.username", fallback: "用户名"), text: $username)
                        .textContentType(.username)
                    if !username.isEmpty && !usernameValid {
                        Text(L10n.k("user.add.form.username.validation", fallback: "用户名只能包含小写字母、数字和下划线，且须以字母开头"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    TextField(L10n.k("user.add.form.full_name", fallback: "全名（显示用）"), text: $fullName)
                } header: {
                    Text(L10n.k("user.add.form.account_info", fallback: "账户信息"))
                }

                Section {
                    SecureField(L10n.k("user.add.form.password", fallback: "密码"), text: $password)
                    SecureField(L10n.k("user.add.form.confirm_password", fallback: "确认密码"), text: $confirmPassword)
                    if !confirmPassword.isEmpty && password != confirmPassword {
                        Text(L10n.k("user.add.form.password.mismatch", fallback: "两次输入的密码不一致"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text(L10n.k("user.add.form.set_password", fallback: "设置密码"))
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(L10n.k("common.action.cancel", fallback: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.k("common.action.create", fallback: "创建")) {
                    onConfirm(username, fullName.isEmpty ? username : fullName, password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 400)
    }
}
