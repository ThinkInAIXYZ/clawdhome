// ClawdHome/Views/DeleteUserSheet.swift

import SwiftUI

// MARK: - 删除家目录选项

enum DeleteHomeOption: Hashable {
    case deleteHome   // 删除个人文件夹（彻底清除）
    case keepHome     // 保留个人文件夹（仅删账户记录）
}

// MARK: - 删除用户确认 Sheet

struct DeleteUserSheet: View {
    let username: String
    let adminUser: String
    @Binding var option: DeleteHomeOption
    @Binding var adminPassword: String
    @State private var showAdminPassword = false
    @FocusState private var isAdminPasswordFocused: Bool
    let isDeleting: Bool
    let error: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题（避免转义符视觉噪音）
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.f("views.user_detail_view.delete_user_title", fallback: "删除用户 @%@", String(describing: username)))
                    .font(.headline)
                Text(L10n.k("views.user_detail_view.delete_user_subtitle", fallback: "此操作不可恢复，请选择个人文件夹处理方式。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // 错误提示
            if let error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.caption)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if isDeleting {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.k("user.detail.auto.deleting_please_wait", fallback: "删除中，请稍候…"))
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(L10n.k("views.user_detail_view.delete_authorization_hint", fallback: "如果系统弹出授权窗口，请点击\u{201C}允许\u{201D}。如果你拒绝了，或者没有出现，请退出程序后重新操作。你也可以前往\u{201C}系统设置 → 用户与群组\u{201D}删除该用户。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            // 选项
                VStack(alignment: .leading, spacing: 0) {
                    optionRow(
                        value: .keepHome,
                        title: L10n.k("user.detail.auto.folder", fallback: "保留个人文件夹"),
                        desc: L10n.f("views.user_detail_view.users", fallback: "/Users/%@/ 保持不变", String(describing: username))
                    )
                    Divider().padding(.leading, 28)
                    optionRow(
                        value: .deleteHome,
                        title: L10n.k("user.detail.auto.deletefolder", fallback: "删除个人文件夹"),
                        desc: L10n.f("views.user_detail_view.users_4c31c5", fallback: "/Users/%@/ 及全部内容将被永久删除", String(describing: username))
                    )
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .disabled(isDeleting)

                // 管理员密码
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("user.detail.auto.adminpassword", fallback: "管理员密码")).font(.subheadline)
                    Text(L10n.f("views.user_detail_view.text_626047b9", fallback: "账号：%@", String(describing: adminUser)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        if showAdminPassword {
                            TextField(L10n.k("user.detail.auto.inputadminpassword", fallback: "请输入管理员登录密码"), text: $adminPassword)
                                .textFieldStyle(.roundedBorder)
                                .id("delete-admin-password-plain")
                                .focused($isAdminPasswordFocused)
                                .onChange(of: isAdminPasswordFocused) { _, focused in
                                    if focused {
                                        KeyboardInputSourceSwitcher.switchToEnglishASCII()
                                    }
                                }
                                .onChange(of: adminPassword) { _, newValue in
                                    let asciiOnly = newValue.filter(\.isASCII)
                                    if asciiOnly != newValue {
                                        adminPassword = asciiOnly
                                    }
                                }
                        } else {
                            SecureField(L10n.k("user.detail.auto.inputadminpassword", fallback: "请输入管理员登录密码"), text: $adminPassword)
                                .textFieldStyle(.roundedBorder)
                                .id("delete-admin-password-secure")
                                .focused($isAdminPasswordFocused)
                                .onChange(of: isAdminPasswordFocused) { _, focused in
                                    if focused {
                                        KeyboardInputSourceSwitcher.switchToEnglishASCII()
                                    }
                                }
                                .onChange(of: adminPassword) { _, newValue in
                                    let asciiOnly = newValue.filter(\.isASCII)
                                    if asciiOnly != newValue {
                                        adminPassword = asciiOnly
                                    }
                                }
                        }
                        Button {
                            showAdminPassword.toggle()
                            isAdminPasswordFocused = true
                        } label: {
                            Image(systemName: showAdminPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(showAdminPassword ? L10n.k("user.detail.auto.password", fallback: "隐藏密码") : L10n.k("user.detail.auto.password", fallback: "显示密码"))
                    }
                }
                .disabled(isDeleting)

                // 按钮
                HStack {
                    Spacer()
                    Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isDeleting)
                    Button(L10n.k("user.detail.auto.deleteuser", fallback: "删除用户"), role: .destructive, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                        .disabled(adminPassword.isEmpty || isDeleting)
                }
        }
        .padding(24)
        .frame(width: 440)
        .onChange(of: isDeleting) { _, deleting in
            if deleting { isAdminPasswordFocused = false }
        }
    }

    @ViewBuilder
    private func optionRow(value: DeleteHomeOption, title: String, desc: String) -> some View {
        Button {
            option = value
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: option == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(option == value ? .blue : .secondary)
                    .font(.system(size: 16))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(desc).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
