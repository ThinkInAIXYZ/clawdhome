// ClawdHome/Views/ProcessTabView.swift

import AppKit
import SwiftUI

// MARK: - 进程管理 Tab

struct ProcessTabView: View {
    let username: String

    @Environment(HelperClient.self) private var helperClient
    @State private var processes: [ProcessEntry] = []
    @State private var isActive = false
    @State private var viewMode: ViewMode = .tree
    @State private var sortField: SortField = .pid
    @State private var sortAsc: Bool = true
    @State private var collapsedPIDs: Set<Int32> = []
    @State private var selectedPIDs: Set<Int32> = []
    @State private var killTargets: [ProcessEntry] = []
    @State private var killError: String? = nil
    @State private var searchText: String = ""
    @State private var isLoading = false
    @State private var portsLoading = false
    @State private var lastUpdatedAt: Date? = nil
    @State private var detailTarget: ProcessEntry? = nil
    @State private var columnWidths = ProcessColumnWidths()

    enum ViewMode: String, CaseIterable, Identifiable {
        case flat = "flat"
        case tree = "tree"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .flat:
                return L10n.k("user.detail.process.view_mode.flat", fallback: "列表")
            case .tree:
                return L10n.k("user.detail.process.view_mode.tree", fallback: "树状")
            }
        }
    }
    enum SortField { case pid, name, cpu, mem, uptime }

    private static let statusTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - 搜索过滤

    private var filtered: [ProcessEntry] {
        guard !searchText.isEmpty else { return processes }
        let q = searchText.lowercased()
        return processes.filter {
            $0.name.lowercased().contains(q) || $0.cmdline.lowercased().contains(q)
        }
    }

    // MARK: - 平铺排序

    private var sorted: [ProcessEntry] {
        let s: (ProcessEntry, ProcessEntry) -> Bool
        switch sortField {
        case .pid:    s = { sortAsc ? $0.pid < $1.pid : $0.pid > $1.pid }
        case .name:   s = { sortAsc ? $0.name < $1.name : $0.name > $1.name }
        case .cpu:    s = { sortAsc ? $0.cpuPercent < $1.cpuPercent : $0.cpuPercent > $1.cpuPercent }
        case .mem:    s = { sortAsc ? $0.memRssMB < $1.memRssMB : $0.memRssMB > $1.memRssMB }
        case .uptime: s = { sortAsc ? $0.elapsedSeconds < $1.elapsedSeconds : $0.elapsedSeconds > $1.elapsedSeconds }
        }
        return filtered.sorted(by: s)
    }

    private var selectedTargets: [ProcessEntry] {
        ProcessBulkActionResolver.resolveTargets(
            selectedPIDs: selectedPIDs,
            processes: processes
        )
    }

    // MARK: - 进程树

    struct TreeNode: Identifiable {
        var id: Int32 { entry.pid }
        let entry: ProcessEntry
        let depth: Int
        let hasChildren: Bool
    }

    private var treeRows: [TreeNode] {
        let source = filtered
        let pidSet = Set(source.map(\.pid))
        let byParent = Dictionary(grouping: source) { $0.ppid }
        func build(_ p: ProcessEntry, depth: Int) -> [TreeNode] {
            let kids = (byParent[p.pid] ?? []).filter { $0.pid != p.pid }.sorted { $0.pid < $1.pid }
            var result = [TreeNode(entry: p, depth: depth, hasChildren: !kids.isEmpty)]
            if !collapsedPIDs.contains(p.pid) {
                for k in kids { result += build(k, depth: depth + 1) }
            }
            return result
        }
        let roots = source
            .filter { !pidSet.contains($0.ppid) || $0.ppid == $0.pid }
            .sorted { $0.pid < $1.pid }
        return roots.flatMap { build($0, depth: 0) }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(L10n.k("user.detail.auto.process", fallback: "进程管理")).font(.headline)
                if searchText.isEmpty {
                    Text(L10n.f("views.user_detail_view.text_f40c2690", fallback: "%@ 个进程", String(describing: processes.count))).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("\(filtered.count) / \(processes.count)").font(.subheadline).foregroundStyle(.secondary)
                }
                if !selectedTargets.isEmpty {
                    Text(L10n.f("views.user_detail_view.text_6ffeae31", fallback: "已选 %@", String(describing: selectedTargets.count)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Text(L10n.k("user.detail.auto.ctrl", fallback: "⌘/Ctrl 多选"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    if isActive {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
                    }
                    Text(isActive ? L10n.k("user.detail.auto.live", fallback: "实时") : L10n.k("user.detail.auto.paused", fallback: "已暂停")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(.bar)

            if !selectedTargets.isEmpty {
                HStack(spacing: 8) {
                    Text(L10n.f("views.user_detail_view.text_5a560471", fallback: "已选 %@ 个进程", String(describing: selectedTargets.count)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.f("views.user_detail_view.text_e80c7665", fallback: "终止已选 (%@)", String(describing: selectedTargets.count))) {
                        killTargets = selectedTargets
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        Task { await doKill(selectedTargets, signal: 9) }
                    } label: {
                        Text(L10n.f("views.user_detail_view.text_6151cab2", fallback: "强制结束已选 (%@)", String(describing: selectedTargets.count)))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()
            }

            // 搜索框
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.k("user.detail.auto.searchprocess", fallback: "搜索进程名或命令行…"), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // 列头
            ProcessColumnHeader(
                viewMode: viewMode,
                sortField: sortField,
                sortAsc: sortAsc,
                widths: $columnWidths
            ) { field in
                if sortField == field { sortAsc.toggle() } else { sortField = field; sortAsc = true }
            }

            Divider()

            // 列表内容
            if isLoading {
                ProgressView(L10n.k("user.detail.auto.loading", fallback: "加载中…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty && isActive {
                Text(searchText.isEmpty ? L10n.k("user.detail.auto.process", fallback: "暂无进程") : L10n.k("user.detail.auto.process", fallback: "无匹配进程")).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewMode == .flat {
                List(sorted, selection: $selectedPIDs) { proc in
                    ProcessRow(
                        proc: proc,
                        depth: 0,
                        hasChildren: false,
                        isCollapsed: false,
                        widths: columnWidths,
                        onToggle: nil
                    )
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .onTapGesture(count: 2) { detailTarget = proc }
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                handleControlToggleSelection(pid: proc.pid)
                            }
                        )
                        .contextMenu { killMenu(proc) }
                }
                .listStyle(.plain)
            } else {
                List(treeRows, selection: $selectedPIDs) { node in
                    ProcessRow(
                        proc: node.entry,
                        depth: node.depth,
                        hasChildren: node.hasChildren,
                        isCollapsed: collapsedPIDs.contains(node.entry.pid),
                        widths: columnWidths,
                        onToggle: {
                            if collapsedPIDs.contains(node.entry.pid) {
                                collapsedPIDs.remove(node.entry.pid)
                            } else {
                                collapsedPIDs.insert(node.entry.pid)
                            }
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .onTapGesture(count: 2) { detailTarget = node.entry }
                    .simultaneousGesture(
                        TapGesture(count: 1).onEnded {
                            handleControlToggleSelection(pid: node.entry.pid)
                        }
                    )
                    .contextMenu { killMenu(node.entry) }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack(spacing: 8) {
                if isLoading || portsLoading {
                    ProgressView().controlSize(.small)
                }
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let t = lastUpdatedAt {
                    Text(L10n.f("views.user_detail_view.text_08170b91", fallback: "更新于 %@", String(describing: Self.statusTimeFormatter.string(from: t))))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
        .onAppear  { isActive = true }
        .onDisappear { isActive = false }
        .task(id: isActive) {
            guard isActive else { return }
            isLoading = true
            while !Task.isCancelled && isActive {
                let snapshot = await helperClient.getProcessListSnapshot(username: username)
                processes = snapshot.entries
                portsLoading = snapshot.portsLoading
                lastUpdatedAt = Date(timeIntervalSince1970: snapshot.updatedAt)
                let livePIDs = Set(snapshot.entries.map(\.pid))
                selectedPIDs.formIntersection(livePIDs)
                isLoading = false
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .confirmationDialog(
            killDialogTitle,
            isPresented: Binding(get: { !killTargets.isEmpty }, set: { if !$0 { killTargets = [] } }),
            titleVisibility: .visible
        ) {
            if !killTargets.isEmpty {
                Button(L10n.k("user.detail.auto.sigterm", fallback: "发送 SIGTERM"), role: .destructive) { Task { await doKill(killTargets, signal: 15) } }
                Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), role: .cancel) { killTargets = [] }
            }
        }
        .alert(L10n.k("user.detail.auto.operation_failed", fallback: "操作失败"), isPresented: Binding(
            get: { killError != nil }, set: { if !$0 { killError = nil } }
        )) {
            Button(L10n.k("user.detail.auto.ok", fallback: "确定"), role: .cancel) { killError = nil }
        } message: { Text(killError ?? "") }
        .sheet(item: $detailTarget) { proc in
            ProcessDetailSheet(base: proc)
        }
    }

    @ViewBuilder
    private func killMenu(_ proc: ProcessEntry) -> some View {
        let targets = contextualKillTargets(for: proc)
        let count = targets.count
        Button { detailTarget = proc } label: {
            Label(L10n.k("views.user_detail_view.view_details", fallback: "查看详情"), systemImage: "info.circle")
        }
        Divider()
        Button { killTargets = targets } label: {
            Label(count > 1
                  ? String(format: L10n.k("views.user_detail_view.kill_selected_sigterm", fallback: "终止选中进程 (%d, SIGTERM)"), count)
                  : L10n.k("views.user_detail_view.process_sigterm", fallback: "终止进程 (SIGTERM)"),
                  systemImage: "stop.circle")
        }
        .disabled(targets.isEmpty)
        Button(role: .destructive) { Task { await doKill(targets, signal: 9) } } label: {
            Label(count > 1
                  ? String(format: L10n.k("views.user_detail_view.force_kill_selected_sigkill", fallback: "强制结束选中进程 (%d, SIGKILL)"), count)
                  : L10n.k("views.user_detail_view.sigkill", fallback: "强制结束 (SIGKILL)"),
                  systemImage: "xmark.circle.fill")
        }
        .disabled(targets.isEmpty)
    }

    private var killDialogTitle: String {
        if killTargets.count == 1, let first = killTargets.first {
            return String(format: L10n.k("views.user_detail_view.kill_process_confirmation", fallback: "终止进程 %@（PID %d）？"), first.name, first.pid)
        }
        return String(format: L10n.k("views.user_detail_view.kill_selected_process_count", fallback: "终止已选中的 %d 个进程？"), killTargets.count)
    }

    private func contextualKillTargets(for proc: ProcessEntry) -> [ProcessEntry] {
        let visiblePIDs: Set<Int32> = {
            if viewMode == .flat { return Set(sorted.map(\.pid)) }
            return Set(treeRows.map(\.id))
        }()
        let effectiveSelected = selectedPIDs.intersection(visiblePIDs)
        return ProcessKillSelectionResolver.resolveTargets(
            clickedPID: proc.pid,
            selectedPIDs: effectiveSelected,
            processes: processes
        )
    }

    private func handleControlToggleSelection(pid: Int32) {
        guard NSApp.currentEvent?.modifierFlags.contains(.control) == true else { return }
        if selectedPIDs.contains(pid) {
            selectedPIDs.remove(pid)
        } else {
            selectedPIDs.insert(pid)
        }
    }

    private func doKill(_ targets: [ProcessEntry], signal: Int32) async {
        killTargets = []
        guard !targets.isEmpty else { return }

        var failures: [String] = []
        for proc in targets {
            do {
                try await helperClient.killProcess(pid: proc.pid, signal: signal)
            } catch {
                failures.append("PID \(proc.pid): \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            selectedPIDs.subtract(targets.map(\.pid))
            return
        }
        killError = failures.count == 1
            ? failures[0]
            : L10n.k("views.user_detail_view.process", fallback: "以下进程操作失败：\n") + failures.joined(separator: "\n")
    }

    private var statusText: String {
        if isLoading { return L10n.k("views.user_detail_view.loading_process_base_info", fallback: "正在加载进程基础信息…") }
        if portsLoading { return L10n.k("views.user_detail_view.port", fallback: "基础信息已就绪，正在补充端口信息…") }
        if processes.isEmpty { return L10n.k("views.user_detail_view.no_process_data", fallback: "暂无进程数据") }
        return String(format: L10n.k("views.user_detail_view.process_port_ready_count", fallback: "进程与端口数据已就绪（%d）"), processes.count)
    }
}

struct ProcessDetailSheet: View {
    let base: ProcessEntry
    @Environment(HelperClient.self) private var helperClient
    @Environment(\.dismiss) private var dismiss

    @State private var detail: ProcessDetail? = nil
    @State private var isLoading = true
    @State private var loadError: String? = nil

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.f("views.user_detail_view.pid_fabd0d", fallback: "进程详情 · PID %@", String(describing: base.pid))).font(.headline)
                Spacer()
                Button(L10n.k("user.detail.auto.close", fallback: "关闭")) { dismiss() }
            }

            if isLoading {
                ProgressView(L10n.k("user.detail.auto.text_1087df4607", fallback: "正在读取详情…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow(L10n.k("user.detail.auto.process", fallback: "进程名"), value: resolved.name)
                        detailRow(L10n.k("user.detail.auto.command_line", fallback: "命令行"), value: resolved.cmdline)
                        detailRow(L10n.k("user.detail.auto.process_pid", fallback: "父进程 PID"), value: "\(resolved.ppid)")
                        detailRow(L10n.k("user.detail.auto.status", fallback: "状态"), value: resolved.stateLabel)
                        detailRow("CPU", value: String(format: "%.1f%%", resolved.cpuPercent))
                        detailRow(L10n.k("user.detail.process.mem", fallback: "内存"), value: resolved.memLabel)
                        detailRow(L10n.k("user.detail.auto.runtime", fallback: "运行时长"), value: resolved.uptimeLabel)
                        detailRow(L10n.k("user.detail.auto.start", fallback: "启动时间"), value: formatTime(resolved.startTime))
                        detailRow(L10n.k("user.detail.auto.port", fallback: "监听端口"), value: resolved.listeningPorts.isEmpty ? "—" : resolved.listeningPorts.joined(separator: ", "))
                        Divider().padding(.vertical, 2)
                        detailRow(L10n.k("user.detail.auto.executable_file", fallback: "可执行文件"), value: resolved.executablePath ?? "—")
                        detailRow(L10n.k("user.detail.auto.file_exists", fallback: "文件存在"), value: resolved.executableExists ? L10n.k("user.detail.auto.yes", fallback: "是") : L10n.k("user.detail.auto.no", fallback: "否"))
                        detailRow(L10n.k("user.detail.auto.file_size", fallback: "文件大小"), value: resolved.executableFileSizeBytes.map(FormatUtils.formatBytes) ?? "—")
                        detailRow(L10n.k("user.detail.auto.created_at", fallback: "创建时间"), value: formatTime(resolved.executableCreatedAt))
                        detailRow(L10n.k("user.detail.auto.modified_at", fallback: "修改时间"), value: formatTime(resolved.executableModifiedAt))
                        detailRow(L10n.k("user.detail.auto.accessed_at", fallback: "访问时间"), value: formatTime(resolved.executableAccessedAt))
                        detailRow(L10n.k("user.detail.auto.metadata_changed", fallback: "元数据变更"), value: formatTime(resolved.executableMetadataChangedAt))
                        detailRow("inode", value: resolved.executableInode.map(String.init) ?? "—")
                        detailRow(L10n.k("user.detail.auto.hard_link_count", fallback: "硬链接数"), value: resolved.executableLinkCount.map(String.init) ?? "—")
                        detailRow(L10n.k("user.detail.auto.owner", fallback: "属主"), value: resolved.executableOwner ?? "—")
                        detailRow(L10n.k("user.detail.auto.permissions", fallback: "权限"), value: resolved.executablePermissions ?? "—")
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 460)
        .task {
            let fetched = await helperClient.getProcessDetail(pid: base.pid)
            detail = fetched
            isLoading = false
            if fetched == nil {
                loadError = L10n.k("user.detail.auto.the_process_may_have_exited_details_are_unavailable", fallback: "进程可能已退出，无法读取详情。")
            }
        }
    }

    private var resolved: ProcessDetail {
        detail ?? ProcessDetail(
            pid: base.pid,
            ppid: base.ppid,
            name: base.name,
            cmdline: base.cmdline,
            cpuPercent: base.cpuPercent,
            memRssMB: base.memRssMB,
            state: base.state,
            elapsedSeconds: base.elapsedSeconds,
            startTime: nil,
            executablePath: nil,
            executableExists: false,
            executableFileSizeBytes: nil,
            executableCreatedAt: nil,
            executableModifiedAt: nil,
            executableAccessedAt: nil,
            executableMetadataChangedAt: nil,
            executableInode: nil,
            executableLinkCount: nil,
            executableOwner: nil,
            executablePermissions: nil,
            listeningPorts: base.listeningPorts
        )
    }

    private func detailRow(_ key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatTime(_ ts: TimeInterval?) -> String {
        guard let ts else { return "—" }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - 列头（独立抽出减轻类型检查压力）

struct ProcessColumnWidths {
    var pid: CGFloat = UserDetailWindowLayout.defaultProcessColumns.pid
    var name: CGFloat = UserDetailWindowLayout.defaultProcessColumns.name
    var command: CGFloat = UserDetailWindowLayout.defaultProcessColumns.command
    var cpu: CGFloat = UserDetailWindowLayout.defaultProcessColumns.cpu
    var mem: CGFloat = UserDetailWindowLayout.defaultProcessColumns.mem
    var uptime: CGFloat = UserDetailWindowLayout.defaultProcessColumns.uptime
    var ports: CGFloat = UserDetailWindowLayout.defaultProcessColumns.ports
    var purpose: CGFloat = UserDetailWindowLayout.defaultProcessColumns.purpose
}

struct ProcessColumnHeader: View {
    let viewMode: ProcessTabView.ViewMode
    let sortField: ProcessTabView.SortField
    let sortAsc: Bool
    @Binding var widths: ProcessColumnWidths
    let onSort: (ProcessTabView.SortField) -> Void

    var body: some View {
        HStack(spacing: 0) {
            pidCol(right: $widths.name) { onSort(.pid) }
            nameCol { onSort(.name) }
            commandCol(right: $widths.cpu)
            cpuCol(right: $widths.mem) { onSort(.cpu) }
            memCol(right: $widths.uptime) { onSort(.mem) }
            uptimeCol(right: $widths.ports) { onSort(.uptime) }
            resizableText(L10n.k("user.detail.auto.port", fallback: "端口"), width: $widths.ports, min: 84, max: 360)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 30, alignment: .center)
        .background(.quaternary.opacity(0.5))
    }

    @ViewBuilder private func pidCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        sortBtn("PID", field: .pid, width: $widths.pid, min: 50, max: 120, align: .trailing,
                rightWidth: right, rightMin: 96, rightMax: 320, action: action)
    }
    @ViewBuilder private func nameCol(action: @escaping () -> Void) -> some View {
        if viewMode == .flat {
            sortBtn(L10n.k("user.detail.auto.process", fallback: "进程名"), field: .name, width: $widths.name, min: 96, max: 320, align: .leading,
                    action: action)
        } else {
            resizableText(L10n.k("user.detail.auto.process", fallback: "进程名"), width: $widths.name, min: 96, max: 320)
        }
    }
    @ViewBuilder private func commandCol(right: Binding<CGFloat>) -> some View {
        // Command 列为弹性列，自动填充剩余空间
        Text("Command")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .overlay(alignment: .trailing) {
                resizeHandle(width: right, min: 48, max: 120)
            }
    }
    @ViewBuilder private func cpuCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        sortBtn("CPU%", field: .cpu, width: $widths.cpu, min: 48, max: 120, align: .trailing,
                rightWidth: right, rightMin: 54, rightMax: 160, action: action)
    }
    @ViewBuilder private func memCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        sortBtn(L10n.k("user.detail.process.mem", fallback: "内存"), field: .mem, width: $widths.mem, min: 54, max: 160, align: .trailing,
                rightWidth: right, rightMin: 48, rightMax: 160, action: action)
    }
    @ViewBuilder private func uptimeCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        sortBtn(L10n.k("user.detail.auto.duration", fallback: "时长"), field: .uptime, width: $widths.uptime, min: 48, max: 160, align: .trailing,
                rightWidth: right, rightMin: 84, rightMax: 360, action: action)
    }

    @ViewBuilder
    private func sortBtn(_ label: String, field: ProcessTabView.SortField,
                         width: Binding<CGFloat>, min: CGFloat, max: CGFloat, align: Alignment,
                         rightWidth: Binding<CGFloat>? = nil, rightMin: CGFloat = 0, rightMax: CGFloat = 0,
                         defaultWidth: CGFloat = 0, defaultRightWidth: CGFloat = 0,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if align == .trailing { Spacer() }
                Text(label).lineLimit(1)
                if sortField == field {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down").font(.system(size: 8))
                }
                if align == .leading { Spacer() }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width.wrappedValue, alignment: align)
        .padding(.horizontal, 4)
        .overlay(alignment: .trailing) {
            resizeHandle(width: width, min: min, max: max, rightWidth: rightWidth, rightMin: rightMin, rightMax: rightMax,
                         defaultWidth: defaultWidth, defaultRightWidth: defaultRightWidth)
        }
    }

    private func resizableText(_ label: String, width: Binding<CGFloat>, min: CGFloat, max: CGFloat,
                               rightWidth: Binding<CGFloat>? = nil, rightMin: CGFloat = 0, rightMax: CGFloat = 0,
                               defaultWidth: CGFloat = 0, defaultRightWidth: CGFloat = 0) -> some View {
        Text(label)
            .lineLimit(1)
            .frame(width: width.wrappedValue, alignment: .leading)
            .padding(.horizontal, 4)
            .overlay(alignment: .trailing) {
                resizeHandle(width: width, min: min, max: max, rightWidth: rightWidth, rightMin: rightMin, rightMax: rightMax,
                             defaultWidth: defaultWidth, defaultRightWidth: defaultRightWidth)
            }
    }

    private func resizeHandle(width: Binding<CGFloat>, min: CGFloat, max: CGFloat,
                              rightWidth: Binding<CGFloat>? = nil, rightMin: CGFloat = 0, rightMax: CGFloat = 0,
                              defaultWidth: CGFloat = 0, defaultRightWidth: CGFloat = 0) -> some View {
        ResizeGrip(width: width, minWidth: min, maxWidth: max,
                   rightWidth: rightWidth, rightMinWidth: rightMin, rightMaxWidth: rightMax,
                   defaultWidth: defaultWidth, defaultRightWidth: defaultRightWidth)
    }
}

// MARK: - 进程行

struct ProcessRow: View {
    let proc: ProcessEntry
    let depth: Int
    let hasChildren: Bool
    let isCollapsed: Bool
    let widths: ProcessColumnWidths
    let onToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            // PID
            Text(verbatim: "\(proc.pid)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: widths.pid, alignment: .trailing)
                .padding(.horizontal, 4)

            // 进程名（树状模式下含缩进 + 折叠按钮）
            HStack(spacing: 0) {
                if depth > 0 {
                    Spacer().frame(width: CGFloat(depth) * 12)
                    Text("╰ ").font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                }
                if hasChildren {
                    Button { onToggle?() } label: {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                } else if depth > 0 {
                    Spacer().frame(width: 14)
                }
                Text(proc.name.isEmpty ? "?" : proc.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: widths.name, alignment: .leading)
            .padding(.horizontal, 4)
            .help(proc.purposeDescription.isEmpty ? proc.cmdline : proc.purposeDescription)

            // Command — 弹性列，可选中，居中截断
            Text(proc.cmdline.isEmpty ? "—" : proc.cmdline)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            // CPU%
            Text(String(format: "%.1f", proc.cpuPercent))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(proc.cpuPercent > 50 ? .orange : .primary)
                .frame(width: widths.cpu, alignment: .trailing)
                .padding(.horizontal, 4)

            // 内存
            Text(proc.memLabel)
                .font(.system(.caption, design: .monospaced))
                .frame(width: widths.mem, alignment: .trailing)
                .padding(.horizontal, 4)

            // 时长
            Text(proc.uptimeLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: widths.uptime, alignment: .trailing)
                .padding(.horizontal, 4)

            // 监听端口
            Text(proc.portsLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: widths.ports, alignment: .leading)
                .padding(.horizontal, 4)
        }
        .padding(.vertical, 2)
    }
}

struct ResizeGrip: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let rightWidth: Binding<CGFloat>?
    let rightMinWidth: CGFloat
    let rightMaxWidth: CGFloat
    var defaultWidth: CGFloat = 0
    var defaultRightWidth: CGFloat = 0
    @State private var baseWidth: CGFloat = 0
    @State private var baseRightWidth: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8, height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if baseWidth == 0 {
                            baseWidth = width
                            baseRightWidth = rightWidth?.wrappedValue ?? 0
                        }

                        // 边界拖拽：向右 => 左列变宽、右列变窄；向左反之。
                        var newLeft = Swift.min(Swift.max(baseWidth + value.translation.width, minWidth), maxWidth)
                        guard let rightWidth else {
                            width = newLeft
                            return
                        }

                        var delta = newLeft - baseWidth
                        var newRight = baseRightWidth - delta
                        if newRight < rightMinWidth {
                            newRight = rightMinWidth
                            delta = baseRightWidth - newRight
                            newLeft = Swift.min(Swift.max(baseWidth + delta, minWidth), maxWidth)
                        } else if newRight > rightMaxWidth {
                            newRight = rightMaxWidth
                            delta = baseRightWidth - newRight
                            newLeft = Swift.min(Swift.max(baseWidth + delta, minWidth), maxWidth)
                        }

                        width = newLeft
                        rightWidth.wrappedValue = newRight
                    }
                    .onEnded { _ in
                        baseWidth = 0
                        baseRightWidth = 0
                    }
            )
            .onTapGesture(count: 2) {
                // 双击重置为默认宽度
                if defaultWidth > 0 {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        width = defaultWidth
                        if let rightWidth, defaultRightWidth > 0 {
                            rightWidth.wrappedValue = defaultRightWidth
                        }
                    }
                }
            }
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 1)
            }
    }
}
