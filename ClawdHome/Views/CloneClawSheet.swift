import AppKit
import SwiftUI

struct CloneClawSheet: View {
    let sourceUsername: String

    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self) private var pool
    @Environment(\.dismiss) private var dismiss

    @State private var targetUsername = ""
    @State private var targetFullName = ""
    @State private var scanResult: CloneScanResult?
    @State private var selectedItemIDs: Set<String> = []
    @State private var progressText = "正在分析可克隆数据与大小，请稍候…"
    @State private var isScanning = true
    @State private var isCloning = false
    @State private var scanError: String?
    @State private var cloneError: String?
    @State private var warnings: [String] = []

    private var isUsernameValid: Bool {
        targetUsername.range(of: #"^[a-z_][a-z0-9_]{0,31}$"#, options: .regularExpression) != nil
    }

    private var selectedSize: Int64 {
        guard let scanResult else { return 0 }
        return CloneClawSelection.selectedSize(items: scanResult.items, selectedIDs: selectedItemIDs)
    }

    private var canSubmit: Bool {
        !isScanning && !isCloning && isUsernameValid && !selectedItemIDs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            inputSection
            scanSection
            excludedSection
            footerSection
        }
        .padding(16)
        .frame(width: 620, height: 620)
        .task { await runScan() }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("克隆新虾")
                .font(.title3).fontWeight(.semibold)
            Text("来源：@\(sourceUsername)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        GroupBox("目标用户") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("目标用户名（必填）", text: $targetUsername)
                    .textContentType(.username)
                    .disabled(isCloning)
                if !targetUsername.isEmpty && !isUsernameValid {
                    Text("用户名只能包含小写字母、数字和下划线，且须以字母或下划线开头")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField("显示名（可选）", text: $targetFullName)
                    .disabled(isCloning)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        GroupBox("可克隆数据（默认全选）") {
            if isScanning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView()
                    Text(progressText).font(.subheadline)
                    Text("会扫描环境目录与配置文件体积，用于勾选和预估复制量。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if let scanError {
                Text(scanError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.vertical, 8)
            } else if let scanResult {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(scanResult.items) { item in
                            cloneItemRow(item)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 230)
            } else {
                Text("暂无扫描结果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    private func cloneItemRow(_ item: CloneScanItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { selectedItemIDs.contains(item.id) },
                set: { isOn in
                    if isOn { selectedItemIDs.insert(item.id) }
                    else { selectedItemIDs.remove(item.id) }
                }
            )) {
                HStack {
                    Text(item.title)
                    Spacer()
                    Text(FormatUtils.formatBytes(item.sizeBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!item.selectable || isCloning)

            Text(item.sourceRelativePath)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let reason = item.disabledReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var excludedSection: some View {
        GroupBox("固定排除（不可勾选）") {
            VStack(alignment: .leading, spacing: 4) {
                Text("• channel 配置")
                Text("• 个性偏好")
                Text("• memory / sessions / logs")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("预计复制总量：\(FormatUtils.formatBytes(selectedSize))")
                .font(.subheadline)
                .monospacedDigit()

            if !warnings.isEmpty {
                Text(warnings.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let cloneError {
                Text(cloneError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCloning)
                Spacer()
                Button(isCloning ? "克隆中…" : "开始克隆") {
                    Task { await runClone() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
    }

    private func runScan() async {
        isScanning = true
        scanError = nil
        warnings = []
        progressText = "正在分析可克隆数据与大小，请稍候…"
        do {
            let result = try await helperClient.scanCloneClaw(username: sourceUsername)
            scanResult = result
            selectedItemIDs = CloneClawSelection.defaultSelectedIDs(items: result.items)
            warnings = result.warnings
        } catch {
            scanError = "扫描失败：\(error.localizedDescription)"
        }
        isScanning = false
    }

    private func runClone() async {
        guard let scanResult else { return }
        isCloning = true
        cloneError = nil
        do {
            let password = try UserPasswordStore.generateAndSave(for: targetUsername)
            let selectedIDs = scanResult.items
                .map(\.id)
                .filter { selectedItemIDs.contains($0) }
            let request = CloneClawRequest(
                sourceUsername: sourceUsername,
                targetUsername: targetUsername,
                targetFullName: targetFullName,
                selectedItemIDs: selectedIDs,
                openWebUIAfterClone: true,
                targetPassword: password
            )
            let result = try await helperClient.cloneClaw(request: request)
            pool.loadUsers()
            if let url = URL(string: result.gatewayURL), !result.gatewayURL.isEmpty {
                NSWorkspace.shared.open(url)
            }
            dismiss()
        } catch {
            cloneError = "克隆失败：\(error.localizedDescription)"
        }
        isCloning = false
    }
}
