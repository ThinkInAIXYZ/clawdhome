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
            Text("添加用户")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.bottom, 16)

            Form {
                Section {
                    TextField("用户名", text: $username)
                        .textContentType(.username)
                    if !username.isEmpty && !usernameValid {
                        Text("用户名只能包含小写字母、数字和下划线，且须以字母开头")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    TextField("全名（显示用）", text: $fullName)
                } header: {
                    Text("账户信息")
                }

                Section {
                    SecureField("密码", text: $password)
                    SecureField("确认密码", text: $confirmPassword)
                    if !confirmPassword.isEmpty && password != confirmPassword {
                        Text("两次输入的密码不一致")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("设置密码")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
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
