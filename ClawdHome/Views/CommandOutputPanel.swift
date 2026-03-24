// ClawdHome/Views/CommandOutputPanel.swift
// 通过 Helper XPC 运行 openclaw 子命令，展示输出结果（无 sudo 密码弹窗）

import SwiftUI

struct CommandOutputPanel: View {
    let username: String
    let args: [String]
    /// 命令完成时回调（true = 成功）
    var onDone: ((Bool) -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient

    @State private var isRunning = true
    @State private var output: String = ""
    @State private var success: Bool? = nil

    private var commandSummary: String {
        "openclaw " + args.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
                Text(commandSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if isRunning {
                    ProgressView().scaleEffect(0.65)
                } else if let ok = success {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ok ? .green : .red)
                        .font(.system(size: 13))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            // 输出区（深色 terminal 风格）
            ScrollView {
                Text(output.isEmpty ? (isRunning ? L10n.k("auto.command_output_panel.text_513a35f0ce", fallback: "运行中…") : L10n.k("auto.command_output_panel.no_output", fallback: "（无输出）")) : output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isRunning || output.isEmpty
                                     ? Color.secondary
                                     : Color(nsColor: .labelColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 80)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
        .task { await run() }
    }

    private func run() async {
        isRunning = true
        output = ""
        success = nil
        let (ok, out) = await helperClient.runOpenclawCommand(username: username, args: args)
        output = out
        success = ok
        isRunning = false
        onDone?(ok)
    }
}
