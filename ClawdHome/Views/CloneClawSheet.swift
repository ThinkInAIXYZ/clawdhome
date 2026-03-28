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
    @State private var progressText = L10n.k("auto.clone_claw_sheet.analyzing_clonable_data_and_size_please_wait", fallback: "正在分析可克隆数据与大小，请稍候…")
    @State private var isScanning = true
    @State private var isCloning = false
    @State private var isCancellingClone = false
    @State private var scanError: String?
    @State private var cloneError: String?
    @State private var warnings: [String] = []
    @State private var cloneStatusText: String?
    @State private var cloneStatusPollingTask: Task<Void, Never>?

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
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            inputSection
            scanSection
            footerSection
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: 620, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await runScan() }
        .onDisappear { stopCloneStatusPolling() }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.k("auto.clone_claw_sheet.clone_shrimp", fallback: "克隆新虾"))
                .font(.title3).fontWeight(.semibold)
            Text(L10n.f("views.clone_claw_sheet.text_f0485c5e", fallback: "来源：@%@", String(describing: sourceUsername)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        GroupBox(L10n.k("auto.clone_claw_sheet.user", fallback: "目标用户")) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L10n.k("auto.clone_claw_sheet.target_username_required", fallback: "目标用户名（必填）"), text: $targetUsername)
                    .textContentType(.username)
                    .disabled(isCloning)
                if !targetUsername.isEmpty && !isUsernameValid {
                    Text(L10n.k("auto.clone_claw_sheet.username", fallback: "用户名只能包含小写字母、数字和下划线，且须以字母或下划线开头"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField(L10n.k("auto.clone_claw_sheet.display_name_optional", fallback: "显示名（可选）"), text: $targetFullName)
                    .disabled(isCloning)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        GroupBox(L10n.k("auto.clone_claw_sheet.select_all", fallback: "可克隆数据（默认全选）")) {
            if isScanning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView()
                    Text(progressText).font(.subheadline)
                    Text(L10n.k("auto.clone_claw_sheet.scans_environment_directories_and_config_sizes_for_selection", fallback: "会扫描环境目录与配置文件体积，用于勾选和预估复制量。"))
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
                Text(L10n.k("auto.clone_claw_sheet.no_scan_results", fallback: "暂无扫描结果"))
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

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.f("views.clone_claw_sheet.text_70867500", fallback: "预计复制总量：%@", String(describing: FormatUtils.formatBytes(selectedSize))))
                .font(.subheadline)
                .monospacedDigit()

            if !warnings.isEmpty {
                Text(warnings.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let cloneStatusText, isCloning {
                Text("当前状态：\(cloneStatusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let cloneError {
                Text(cloneError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isCloning {
                    Button(isCancellingClone
                           ? L10n.k("views.clone_claw_sheet.cancelling", fallback: "终止中…")
                           : L10n.k("views.clone_claw_sheet.cancel_clone", fallback: "终止克隆")) {
                        Task { await requestCancelClone() }
                    }
                    .disabled(isCancellingClone)
                } else {
                    Button(L10n.k("auto.clone_claw_sheet.cancel", fallback: "取消")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(isCloning ? L10n.k("auto.clone_claw_sheet.text_4699ebd9fe", fallback: "克隆中…") : L10n.k("auto.clone_claw_sheet.start_cloning", fallback: "开始克隆")) {
                    Task { await runClone() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isCancellingClone)
            }
        }
    }

    private func runScan() async {
        isScanning = true
        scanError = nil
        warnings = []
        progressText = L10n.k("auto.clone_claw_sheet.analyzing_clonable_data_and_size_please_wait", fallback: "正在分析可克隆数据与大小，请稍候…")
        do {
            let result = try await helperClient.scanCloneClaw(username: sourceUsername)
            scanResult = result
            selectedItemIDs = CloneClawSelection.defaultSelectedIDs(items: result.items)
            warnings = result.warnings
        } catch {
            scanError = L10n.f("views.clone_claw_sheet.text_985cdafc", fallback: "扫描失败：%@", String(describing: error.localizedDescription))
        }
        isScanning = false
    }

    private func runClone() async {
        guard let scanResult else { return }
        isCloning = true
        cloneError = nil
        cloneStatusText = nil
        startCloneStatusPolling()
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
            cloneError = L10n.f("views.clone_claw_sheet.text_c6c6eeb2", fallback: "克隆失败：%@", String(describing: error.localizedDescription))
        }
        stopCloneStatusPolling()
        isCloning = false
    }

    private func requestCancelClone() async {
        guard isCloning else { return }
        isCancellingClone = true
        do {
            try await helperClient.cancelCloneClaw(targetUsername: targetUsername)
            cloneError = L10n.k("views.clone_claw_sheet.cancel_requested", fallback: "已请求终止克隆，正在停止…")
        } catch {
            cloneError = L10n.f("views.clone_claw_sheet.cancel_failed", fallback: "终止克隆失败：%@", String(describing: error.localizedDescription))
        }
        isCancellingClone = false
    }

    private func startCloneStatusPolling() {
        stopCloneStatusPolling()
        let username = targetUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return }

        cloneStatusPollingTask = Task {
            while !Task.isCancelled {
                if let status = await helperClient.getCloneClawStatus(targetUsername: username) {
                    await MainActor.run { cloneStatusText = status }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func stopCloneStatusPolling() {
        cloneStatusPollingTask?.cancel()
        cloneStatusPollingTask = nil
    }
}
