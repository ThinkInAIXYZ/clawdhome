// ClawdHome/Views/UserFilesView.swift
// 每只虾的文件浏览器：浏览整个 home 目录，支持上传/下载/删除/新建文件夹/文本编辑
import SwiftUI
import AppKit

/// AppKit 桥接：
/// 1. 将 NSTableView 设为 firstResponder（解决初次点击只激活、不选中问题）
/// 2. 注册 doubleAction（替代 SwiftUI 手势，手势会干扰 Table 内置选中逻辑）
private struct TableSetup: NSViewRepresentable {
    /// 双击时传入 clickedRow，由调用方映射到 entries
    var onDoubleClick: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDoubleClick: onDoubleClick) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.attachTableView(startingFrom: view, coordinator: context.coordinator, retries: 8)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDoubleClick = onDoubleClick
        DispatchQueue.main.async {
            Self.attachTableView(startingFrom: nsView, coordinator: context.coordinator, retries: 2)
        }
    }

    /// 从给定 NSView 向上爬，在同层或父层子树中寻找 NSTableView
    private static func findTableView(startingFrom view: NSView) -> NSTableView? {
        var current: NSView? = view
        for _ in 0..<12 {
            guard let node = current else { break }
            if let tv = searchDescendants(of: node) { return tv }
            current = node.superview
        }
        return nil
    }

    private static func searchDescendants(of view: NSView) -> NSTableView? {
        if let tv = view as? NSTableView { return tv }
        if let sv = view as? NSScrollView, let tv = sv.documentView as? NSTableView { return tv }
        for sub in view.subviews {
            if let found = searchDescendants(of: sub) { return found }
        }
        return nil
    }

    private static func attachTableView(startingFrom view: NSView, coordinator: Coordinator, retries: Int) {
        if let tableView = findTableView(startingFrom: view) {
            coordinator.bind(tableView: tableView)
            return
        }
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            attachTableView(startingFrom: view, coordinator: coordinator, retries: retries - 1)
        }
    }

    final class Coordinator: NSObject {
        var onDoubleClick: (Int) -> Void
        weak var tableView: NSTableView?

        init(onDoubleClick: @escaping (Int) -> Void) { self.onDoubleClick = onDoubleClick }

        func bind(tableView: NSTableView) {
            self.tableView = tableView
            tableView.window?.makeFirstResponder(tableView)
            tableView.doubleAction = #selector(doubleClicked(_:))
            tableView.target = self
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0 else { return }
            onDoubleClick(row)
        }
    }
}

/// 文本编辑器状态——原子性传入 sheet，避免 SwiftUI 渲染时机问题
private struct TextEditState: Identifiable {
    var id: String { entry.id }
    let entry: FileEntry
    let content: String     // 只读初始值，编辑状态由 TextEditSheetView 的 @State 管理
}

/// 文本编辑器 Sheet——持有自己的 @State，避免父视图值语义导致 Binding 失效
private struct TextEditSheetView: View {
    let state: TextEditState
    var onSave: (String) async -> Void
    var onCancel: () -> Void

    @State private var content: String
    @State private var isSaving = false
    @State private var showFind = false
    @State private var jsonError: String?

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    init(state: TextEditState,
         onSave: @escaping (String) async -> Void,
         onCancel: @escaping () -> Void) {
        self.state = state
        self.onSave = onSave
        self.onCancel = onCancel
        _content = State(initialValue: state.content)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.f("views.user_files_view.text_f79700ab", fallback: "编辑：%@", String(describing: state.entry.name)))
                            .font(.headline)
                        if state.entry.size == 0 {
                            Text(L10n.k("auto.user_files_view.file", fallback: "文件内容为空"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(byteFormatter.string(fromByteCount: state.entry.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        showFind.toggle()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .help(L10n.k("auto.user_files_view.f", fallback: "查找 (⌘F)"))
                    Button(L10n.k("auto.user_files_view.cancel", fallback: "取消")) { onCancel() }
                    Button(L10n.k("auto.user_files_view.save", fallback: "保存")) {
                        isSaving = true
                        Task {
                            await onSave(content)
                            isSaving = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
                .padding()

                if let jsonError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(jsonError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .zIndex(1)

            Divider()
            CodeEditorView(text: $content, showFind: $showFind)
                .clipped()
        }
        .frame(
            minWidth: 750,
            idealWidth: 920,
            minHeight: 500,
            idealHeight: 680
        )
        .onChange(of: content) { _, newValue in
            validateJSON(newValue)
        }
        .onAppear { validateJSON(content) }
    }

    private var isJSONFile: Bool {
        let ext = (state.entry.name as NSString).pathExtension.lowercased()
        return ["json", "json5"].contains(ext)
    }

    private func validateJSON(_ text: String) {
        guard isJSONFile else { jsonError = nil; return }
        guard let data = text.data(using: .utf8) else { jsonError = nil; return }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            jsonError = nil
        } catch {
            let desc = error.localizedDescription
            // 提取关键信息，去掉冗长前缀
            if let range = desc.range(of: "around ") {
                jsonError = L10n.f("views.user_files_view.json", fallback: "JSON 语法错误：%@", String(describing: desc[range.lowerBound...]))
            } else if let range = desc.range(of: "line ") {
                jsonError = L10n.f("views.user_files_view.json", fallback: "JSON 语法错误：%@", String(describing: desc[range.lowerBound...]))
            } else {
                jsonError = L10n.k("auto.user_files_view.json", fallback: "JSON 语法错误")
            }
        }
    }
}

// MARK: - 行号侧栏（NSRulerView，随 NSTextView 滚动自动同步）

private final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?

    override var isFlipped: Bool { true }

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 40
    }

    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let lm = textView.layoutManager,
              let cv = scrollView?.contentView else { return }

        // 背景
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // 右侧分隔线
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: ruleThickness - 0.5, y: bounds.minY))
        sep.line(to: NSPoint(x: ruleThickness - 0.5, y: bounds.maxY))
        sep.lineWidth = 0.5
        sep.stroke()

        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        let string = textView.string as NSString
        let textLen = string.length
        let scrollY = cv.bounds.minY                 // 当前滚动偏移
        let inset = textView.textContainerInset.height
        let glyphCount = lm.numberOfGlyphs

        // 空文本仍显示第 1 行
        if glyphCount == 0 {
            drawNum(1, y: inset - scrollY, h: font.boundingRectForFont.height, attrs: attrs)
            return
        }

        var lineNum = 1
        var charIdx = 0

        while charIdx <= textLen {
            let gIdx = charIdx < textLen ? lm.glyphIndexForCharacter(at: charIdx) : glyphCount - 1
            guard gIdx < glyphCount else { break }

            let frag = lm.lineFragmentRect(forGlyphAt: gIdx, effectiveRange: nil)
            let y = frag.minY + inset - scrollY          // ruler 坐标系中的 y

            if y >= rect.minY - frag.height && y < rect.maxY {
                drawNum(lineNum, y: y, h: frag.height, attrs: attrs)
            }
            if y >= rect.maxY { break }
            guard charIdx < textLen else { break }

            let lr = string.lineRange(for: NSRange(location: charIdx, length: 0))
            let next = NSMaxRange(lr)
            if next <= charIdx { break }
            charIdx = next
            lineNum += 1
        }
    }

    private func drawNum(_ n: Int, y: CGFloat, h: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let s = "\(n)" as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: ruleThickness - sz.width - 6, y: y + (h - sz.height) / 2),
               withAttributes: attrs)
    }
}

// MARK: - 代码编辑器（NSTextView 封装，含行号 Ruler、Find Bar、禁用智能替换）

private struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var showFind: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let tv = scrollView.documentView as! NSTextView

        // 自动宽度跟随视图，纵向无限延伸
        tv.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true

        // 字体
        tv.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.isRichText = false
        tv.usesFontPanel = false
        tv.allowsUndo = true

        // 关闭智能替换（代码/配置文件编辑时不能乱改）
        tv.isAutomaticQuoteSubstitutionEnabled  = false
        tv.isAutomaticDashSubstitutionEnabled   = false
        tv.isAutomaticTextReplacementEnabled    = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled     = false
        tv.isGrammarCheckingEnabled             = false

        // 内联 Find Bar
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true

        // 行号侧栏
        let ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        ruler.textView = tv
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        tv.delegate = context.coordinator
        context.coordinator.ruler = ruler
        tv.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let tv = scrollView.documentView as! NSTextView
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, text.utf16.count), length: 0))
            scrollView.verticalRulerView?.needsDisplay = true
        }
        // 触发 Find Bar（usesFindBar = true 时显示内联搜索栏）
        if showFind && !context.coordinator.findShown {
            context.coordinator.findShown = true
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                let actionItem = NSMenuItem()
                actionItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                tv.performFindPanelAction(actionItem)
            }
        } else if !showFind {
            context.coordinator.findShown = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var ruler: LineNumberRulerView?
        var findShown = false

        init(text: Binding<String>) { _text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
            ruler?.needsDisplay = true
        }
    }
}

/// 检测数据是否为二进制（前 8 KB 含 null 字节则判定为二进制）
private func looksLikeBinary(_ data: Data) -> Bool {
    let sample = data.prefix(8192)
    return sample.contains(0)
}

struct UserFilesView: View {
    let users: [ManagedUser]
    /// 嵌入单用户 Tab 时传入，自动选中并隐藏用户选择器
    var preselectedUser: ManagedUser? = nil
    /// 仅用于详情页预选用户模式：按天记忆每个用户在文件页的最后目录
    private static var preselectedDailyPathByUser: [String: (dayKey: String, path: String)] = [:]

    @Environment(HelperClient.self) private var helperClient
    @Environment(\.openWindow) private var openWindow
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry

    @State private var selectedUser: ManagedUser?
    @State private var currentPath: String = ""      // 相对 home 的路径
    @State private var entries: [FileEntry] = []
    // Table selection uses the ID type (String = FileEntry.path)
    // contextMenu(forSelectionType:) requires Set-based (multi) selection to fire
    @State private var selectedEntryIDs: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?      // 目录加载失败
    @State private var operationError: String?    // 上传/删除等操作失败（独立 banner）
    @State private var sortField: FileSortField = .name
    @State private var sortAscending = true

    // 文本编辑器（用 item 模式保证状态原子性）
    @State private var textEditState: TextEditState?

    // 删除确认
    @State private var showDeleteConfirm = false

    // 新建文件夹
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""

    // 重命名
    @State private var renameTarget: FileEntry?
    @State private var renameText = ""          // 不含后缀的编辑值
    @State private var renameExt = ""           // 原始后缀（含点），若目录则为空
    /// 仅在“默认自动进入 .openclaw”场景启用不存在时回退到 home
    @State private var shouldFallbackMissingOpenClaw = false

    // 显示隐藏文件（默认开启，.openclaw 等隐藏目录是主要管理对象）
    @State private var showHidden = true

    // 上传进度
    @State private var uploadStatus: UploadStatus? = nil
    @State private var isUploadDropTargeted = false

    private enum UploadStatus {
        case singleUpload(name: String)
        case folderUpload(current: Int, total: Int, name: String)
        case extracting(name: String)

        var label: String {
            switch self {
            case .singleUpload(let name):
                return String(format: L10n.k("views.user_files_view.uploading_item", fallback: "正在上传 %@…"), name)
            case .folderUpload(let current, let total, let name):
                return String(format: L10n.k("views.user_files_view.uploading_progress_item", fallback: "正在上传 %d/%d：%@…"), current, total, name)
            case .extracting(let name):
                return String(format: L10n.k("views.user_files_view.extracting_item", fallback: "正在解压 %@…"), name)
            }
        }

        var progress: Double? {
            switch self {
            case .singleUpload, .extracting:
                return nil
            case .folderUpload(let current, let total, _):
                return total > 0 ? Double(current) / Double(total) : 0
            }
        }
    }

    // 快速入口（相对于 home 的路径）—— 用户 Home 单独渲染为头像按钮
    private let quickAccessItems: [(label: String, icon: String, path: String)] = [
        ("🦞 Home", "externaldrive",  ".openclaw"),
    ]

    // 面包屑：路径组件
    private var breadcrumbs: [String] {
        currentPath.isEmpty ? [] : currentPath.components(separatedBy: "/")
    }

    // 从 ID 反查选中条目
    private var selectedEntry: FileEntry? {
        guard selectedEntryIDs.count == 1 else { return nil }
        guard let id = selectedEntryIDs.first else { return nil }
        return sortedEntries.first { $0.id == id }
    }

    private var selectedEntries: [FileEntry] {
        sortedEntries.filter { selectedEntryIDs.contains($0.id) }
    }

    private var sortedEntries: [FileEntry] {
        entries.sorted(by: shouldComeBefore)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            Divider()

            if !helperClient.isConnected {
                ContentUnavailableView(
                    L10n.k("auto.user_files_view.helper", fallback: "Helper 未连接"),
                    systemImage: "folder.badge.questionmark",
                    description: Text(L10n.k("auto.user_files_view.settings_start_helper", fallback: "请前往「设置 → 诊断」安装或启动 Helper"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedUser == nil {
                ContentUnavailableView(
                    L10n.k("auto.user_files_view.select", fallback: "选择一只虾"),
                    systemImage: "person.crop.circle",
                    description: Text(L10n.k("auto.user_files_view.selectfile", fallback: "在顶部下拉菜单选择要管理文件的虾"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 已选虾：显示快速入口 + 面包屑 + 文件列表
                quickAccessBar
                Divider()
                breadcrumbBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
                uploadDropHintBar

                if let opErr = operationError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(opErr)
                            .font(.caption)
                            .foregroundStyle(.primary)
                        Spacer()
                        Button {
                            operationError = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                }

                if isLoading {
                    ProgressView(L10n.k("auto.user_files_view.loading", fallback: "加载中…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    ContentUnavailableView(
                        L10n.k("auto.user_files_view.load_failed", fallback: "加载失败"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(err)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    fileList
                }
            }

            // 上传进度条
            if let status = uploadStatus {
                Divider()
                HStack(spacing: 10) {
                    if let progress = status.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                    } else {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        .navigationTitle(L10n.k("auto.user_files_view.files", fallback: "文件"))
        .sheet(item: $textEditState) { state in
            TextEditSheetView(state: state) { savedContent in
                await saveTextEdit(entry: state.entry, content: savedContent)
            } onCancel: {
                textEditState = nil
            }
        }
        .alert(L10n.k("auto.user_files_view.delete", fallback: "确认删除"), isPresented: $showDeleteConfirm) {
            Button(L10n.k("auto.user_files_view.delete", fallback: "删除"), role: .destructive) { Task { await deleteSelected() } }
            Button(L10n.k("auto.user_files_view.cancel", fallback: "取消"), role: .cancel) {}
        } message: {
            if selectedEntries.count <= 1, let entry = selectedEntries.first {
                Text(L10n.f("views.user_files_view.text_f797a8c4", fallback: "删除「%@」？此操作不可撤销。", String(describing: entry.name)))
            } else {
                Text(
                    L10n.f(
                        "views.user_files_view.confirm_delete_multiple",
                        fallback: "删除已选中的 %d 项？此操作不可撤销。",
                        selectedEntries.count
                    )
                )
            }
        }
        .alert(L10n.k("auto.user_files_view.folder", fallback: "新建文件夹"), isPresented: $showNewFolderAlert) {
            TextField(L10n.k("auto.user_files_view.foldername", fallback: "文件夹名称"), text: $newFolderName)
            Button(L10n.k("auto.user_files_view.create", fallback: "创建")) { Task { await createFolder() } }
            Button(L10n.k("auto.user_files_view.cancel", fallback: "取消"), role: .cancel) { newFolderName = "" }
        }
        .alert(L10n.k("auto.user_files_view.rename", fallback: "重命名"), isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        ), presenting: renameTarget) { target in
            TextField(target.isDirectory ? L10n.k("auto.user_files_view.foldername", fallback: "文件夹名称") : L10n.k("auto.user_files_view.file_name_without_extension", fallback: "文件名（不含后缀）"),
                      text: $renameText)
            Button(L10n.k("auto.user_files_view.rename", fallback: "重命名")) { Task { await commitRename() } }
            Button(L10n.k("auto.user_files_view.cancel", fallback: "取消"), role: .cancel) { renameTarget = nil }
        } message: { target in
            if renameExt.isEmpty {
                Text(L10n.f("views.user_files_view.text_07f4232d", fallback: "重命名「%@」", String(describing: target.name)))
            } else {
                Text(L10n.f("views.user_files_view.text_1b3c25ab", fallback: "重命名「%@」（后缀 %@ 将自动保留）", String(describing: target.name), String(describing: renameExt)))
            }
        }
        .onChange(of: selectedUser) { _, user in
            guard preselectedUser == nil else { return }
            if user != nil {
                currentPath = ".openclaw"
                shouldFallbackMissingOpenClaw = true
                selectedEntryIDs = []
                showHidden = true
                Task { await loadDirectory() }
            }
        }
        .onAppear {
            // 嵌入详情 Tab 时：仅首次进入该用户文件页自动跳到 .openclaw
            if let pre = preselectedUser {
                activatePreselectedUser(pre)
            }
        }
        .onChange(of: preselectedUser?.id) { _, _ in
            guard let pre = preselectedUser else { return }
            activatePreselectedUser(pre)
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            // 虾选择器：嵌入详情 Tab 时（preselectedUser != nil）隐藏
            if preselectedUser == nil {
                Picker(L10n.k("auto.user_files_view.shrimp", fallback: "虾"), selection: $selectedUser) {
                    Text(L10n.k("auto.user_files_view.select", fallback: "选择虾…")).tag(Optional<ManagedUser>.none)
                    ForEach(users.filter { !$0.isAdmin }) { user in
                        Text(user.username).tag(Optional(user))
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            Spacer()

            // 新建文件夹
            Button {
                newFolderName = ""
                showNewFolderAlert = true
            } label: {
                Label(L10n.k("auto.user_files_view.folder", fallback: "新建文件夹"), systemImage: "folder.badge.plus")
            }
            .disabled(selectedUser == nil)

            // 显示/隐藏文件切换
            Button {
                showHidden.toggle()
                Task { await loadDirectory() }
            } label: {
                Label(showHidden ? L10n.k("auto.user_files_view.file", fallback: "隐藏隐藏文件") : L10n.k("auto.user_files_view.file", fallback: "显示隐藏文件"),
                      systemImage: showHidden ? "eye.slash" : "eye")
            }
            .disabled(selectedUser == nil)

            // 上传
            Button {
                Task { await uploadFile() }
            } label: {
                Label(L10n.k("auto.user_files_view.upload", fallback: "上传"), systemImage: "arrow.up.doc")
            }
            .disabled(selectedUser == nil)

            Menu {
                Picker(L10n.k("views.user_files_view.sort_by", fallback: "排序方式"), selection: $sortField) {
                    Text(L10n.k("auto.user_files_view.name", fallback: "名称")).tag(FileSortField.name)
                    Text(L10n.k("auto.user_files_view.size", fallback: "大小")).tag(FileSortField.size)
                    Text(L10n.k("auto.user_files_view.modified_at", fallback: "修改时间")).tag(FileSortField.modifiedAt)
                }
                Divider()
                Button {
                    sortAscending.toggle()
                } label: {
                    Label(
                        sortAscending
                            ? L10n.k("views.user_files_view.ascending", fallback: "升序")
                            : L10n.k("views.user_files_view.descending", fallback: "降序"),
                        systemImage: sortAscending ? "arrow.up" : "arrow.down"
                    )
                }
            } label: {
                Label(L10n.k("views.user_files_view.sort", fallback: "排序"), systemImage: "arrow.up.arrow.down")
            }
            .disabled(selectedUser == nil)

            // 下载（选中文件时激活）
            Button {
                Task { await downloadSelected() }
            } label: {
                Label(L10n.k("auto.user_files_view.download", fallback: "下载"), systemImage: "arrow.down.doc")
            }
            .disabled(selectedEntry == nil || selectedEntry?.isDirectory == true)

            // 编辑（文本文件时激活）
            Button {
                Task { await openTextEditor() }
            } label: {
                Label(L10n.k("auto.user_files_view.edit", fallback: "编辑"), systemImage: "pencil")
            }
            .disabled(!canEditSelected)

            // 终端
            Button {
                openTerminalAtCurrentPath()
            } label: {
                Label(L10n.k("auto.user_files_view.terminal", fallback: "终端"), systemImage: "apple.terminal")
            }
            .disabled(selectedUser == nil)
            .help(L10n.k("auto.user_files_view.opendirectory", fallback: "在终端打开当前目录"))

            // 删除
            Button {
                showDeleteConfirm = true
            } label: {
                Label(
                    selectedEntries.count > 1
                        ? L10n.f(
                            "views.user_files_view.delete_count",
                            fallback: "删除（%d）",
                            selectedEntries.count
                        )
                        : L10n.k("auto.user_files_view.delete", fallback: "删除"),
                    systemImage: "trash"
                )
                .foregroundStyle(!selectedEntries.isEmpty ? .red : .secondary)
            }
            .disabled(selectedEntries.isEmpty)
        }
    }

    // MARK: - 快速入口

    private var quickAccessBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // 用户 Home 头像按钮
                if let user = selectedUser {
                    Button {
                        currentPath = ""
                        selectedEntryIDs = []
                        Task { await loadDirectory() }
                    } label: {
                        HStack(spacing: 5) {
                            Text("🧑")
                                .font(.caption)
                            Text(user.username)
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                ForEach(quickAccessItems, id: \.path) { item in
                    Button {
                        currentPath = item.path
                        shouldFallbackMissingOpenClaw = false
                        selectedEntryIDs = []
                        Task { await loadDirectory() }
                    } label: {
                        Label(item.label, systemImage: item.icon)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedUser == nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 面包屑

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            Button("🏠 Home") {
                currentPath = ""
                Task { await loadDirectory() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                Text("›")
                    .foregroundStyle(.secondary)
                Button(crumb) {
                    // 跳到面包屑某一层
                    currentPath = breadcrumbs[0...idx].joined(separator: "/")
                    Task { await loadDirectory() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            Spacer()

            Button {
                copyCurrentPathToPasteboard()
            } label: {
                Label(L10n.k("auto.user_files_view.copy_current_path", fallback: "复制当前路径"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help(L10n.k("auto.user_files_view.directory", fallback: "复制当前目录路径"))
        }
        .font(.subheadline)
    }

    // MARK: - 文件列表

    private var uploadDropHintBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .foregroundStyle(.secondary)
            Text(L10n.k("auto.user_files_view.filefolderdirectory", fallback: "支持将文件或文件夹直接拖入下方列表上传到当前目录"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }

    private var fileList: some View {
        Table(sortedEntries, selection: $selectedEntryIDs) {
            TableColumn(L10n.k("auto.user_files_view.name", fallback: "名称")) { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon(for: entry.name))
                        .foregroundStyle(entry.isDirectory ? .yellow : .secondary)
                    Text(entry.name)
                    if entry.isSymlink {
                        Image(systemName: "arrow.triangle.turn.up.right.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
            .width(min: 160, ideal: 280)

            TableColumn(L10n.k("auto.user_files_view.size", fallback: "大小")) { entry in
                if entry.isDirectory {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    Text(formatSize(entry.size))
                }
            }
            .width(min: 60, ideal: 80)

            TableColumn(L10n.k("auto.user_files_view.modified_at", fallback: "修改时间")) { entry in
                if let date = entry.modifiedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 120, ideal: 160)

            TableColumn(L10n.k("auto.user_files_view.owner", fallback: "所有者")) { entry in
                if let owner = entry.ownerUsername {
                    let isExpected = owner == selectedUser?.username
                    Text(owner)
                        .foregroundStyle(isExpected ? Color.primary : Color.orange)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 100)
        }
        .dropDestination(for: URL.self) { droppedURLs, _ in
            let fileURLs = droppedURLs.filter(\.isFileURL)
            guard selectedUser != nil, !fileURLs.isEmpty else { return false }
            Task { await uploadDroppedItems(fileURLs) }
            return true
        } isTargeted: { isTargeted in
            isUploadDropTargeted = isTargeted
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.isEmpty {
                Button { Task { await uploadFile() } } label: {
                    Label(L10n.k("auto.user_files_view.filefolder", fallback: "上传文件或文件夹…"), systemImage: "arrow.up.doc")
                }
                Button {
                    newFolderName = ""
                    showNewFolderAlert = true
                } label: {
                    Label(L10n.k("auto.user_files_view.folder", fallback: "新建文件夹…"), systemImage: "folder.badge.plus")
                }
                Divider()
                Button { openTerminalAtCurrentPath() } label: {
                    Label(L10n.k("auto.user_files_view.open", fallback: "在终端中打开"), systemImage: "apple.terminal")
                }
                Button {
                    copyCurrentPathToPasteboard()
                } label: {
                    Label(L10n.k("auto.user_files_view.copy_current_path", fallback: "复制当前路径"), systemImage: "doc.on.doc")
                }
            } else if let id = ids.first,
                      let entry = entries.first(where: { $0.id == id }) {
                if entry.isDirectory {
                    Button {
                        selectedEntryIDs = [entry.id]
                        navigateInto(entry)
                    } label: {
                        Label(L10n.k("auto.user_files_view.directory", fallback: "进入目录"), systemImage: "folder.fill")
                    }
                    Divider()
                    Button(L10n.k("auto.user_files_view.rename", fallback: "重命名…")) {
                        selectedEntryIDs = [entry.id]
                        beginRename(entry)
                    }
                    Divider()
                    Button { openTerminalAtCurrentPath() } label: {
                        Label(L10n.k("auto.user_files_view.open", fallback: "在终端中打开"), systemImage: "apple.terminal")
                    }
                    Button {
                        copyEntryPathToPasteboard(entry)
                    } label: {
                        Label(L10n.k("auto.user_files_view.copy_path", fallback: "复制路径"), systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(L10n.k("auto.user_files_view.delete", fallback: "删除…"), role: .destructive) {
                        selectedEntryIDs = [entry.id]
                        showDeleteConfirm = true
                    }
                } else {
                    Button {
                        selectedEntryIDs = [entry.id]
                        Task { await openTextEditor() }
                    } label: {
                        Label(L10n.k("auto.user_files_view.edit", fallback: "编辑"), systemImage: "pencil")
                    }
                    Button {
                        selectedEntryIDs = [entry.id]
                        Task { await downloadSelected() }
                    } label: {
                        Label(L10n.k("auto.user_files_view.download", fallback: "下载"), systemImage: "arrow.down.doc")
                    }
                    if isArchive(entry.name) {
                        Button {
                            selectedEntryIDs = [entry.id]
                            Task { await extractSelected() }
                        } label: {
                            Label(L10n.k("auto.user_files_view.directory", fallback: "解压到当前目录"), systemImage: "archivebox.circle")
                        }
                    }
                    Divider()
                    Button(L10n.k("auto.user_files_view.rename", fallback: "重命名…")) {
                        selectedEntryIDs = [entry.id]
                        beginRename(entry)
                    }
                    Divider()
                    Button { openTerminalAtCurrentPath() } label: {
                        Label(L10n.k("auto.user_files_view.open", fallback: "在终端中打开"), systemImage: "apple.terminal")
                    }
                    Button {
                        copyEntryPathToPasteboard(entry)
                    } label: {
                        Label(L10n.k("auto.user_files_view.copy_path", fallback: "复制路径"), systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(L10n.k("auto.user_files_view.delete", fallback: "删除…"), role: .destructive) {
                        selectedEntryIDs = [entry.id]
                        showDeleteConfirm = true
                    }
                }
            }
        }
        // AppKit 桥接：自动获焦 + 原生双击进目录（不干扰 Table 选中）
        .background(
            TableSetup { [sortedEntries] row in
                guard row < sortedEntries.count else { return }
                let entry = sortedEntries[row]
                if entry.isDirectory {
                    navigateInto(entry)
                } else {
                    selectedEntryIDs = [entry.id]
                    Task { await openTextEditor() }
                }
            }
        )
        .overlay {
            if isUploadDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    )
                    .overlay(
                        Label(L10n.k("auto.user_files_view.filefolderdirectory", fallback: "拖入文件或文件夹上传到当前目录"), systemImage: "arrow.down.doc.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    )
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 辅助

    private var canEditSelected: Bool {
        guard let entry = selectedEntry else { return false }
        return !entry.isDirectory
    }

    private func isArchive(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".zip")
            || lower.hasSuffix(".tar.gz")
            || lower.hasSuffix(".tgz")
            || lower.hasSuffix(".tar.bz2")
            || lower.hasSuffix(".tbz2")
            || lower.hasSuffix(".tar.xz")
            || lower.hasSuffix(".txz")
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "svg": return "photo"
        case "pdf":                                        return "doc.richtext"
        case "zip", "gz", "tar", "bz2", "xz":            return "archivebox"
        case "sh":                                         return "terminal"
        default:                                           return "doc.text"
        }
    }

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    private func formatSize(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    private enum FileSortField: String, CaseIterable {
        case name
        case size
        case modifiedAt
    }

    private func shouldComeBefore(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }

        let ordering: ComparisonResult
        switch sortField {
        case .name:
            ordering = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .size:
            if lhs.size != rhs.size {
                ordering = lhs.size < rhs.size ? .orderedAscending : .orderedDescending
            } else {
                ordering = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            }
        case .modifiedAt:
            let lDate = lhs.modifiedAt ?? .distantPast
            let rDate = rhs.modifiedAt ?? .distantPast
            if lDate != rDate {
                ordering = lDate < rDate ? .orderedAscending : .orderedDescending
            } else {
                ordering = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            }
        }

        let primaryAscending: Bool
        switch ordering {
        case .orderedAscending:
            primaryAscending = true
        case .orderedDescending:
            primaryAscending = false
        case .orderedSame:
            primaryAscending = lhs.path < rhs.path
        }
        return sortAscending ? primaryAscending : !primaryAscending
    }

    private func navigateInto(_ entry: FileEntry) {
        currentPath = entry.path
        selectedEntryIDs = []
        Task { await loadDirectory() }
    }

    private static func dayKey(for date: Date = Date()) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func recordCurrentPathForToday(_ path: String) {
        guard let user = selectedUser, preselectedUser != nil else { return }
        Self.preselectedDailyPathByUser[user.username] = (Self.dayKey(), path)
    }

    private func activatePreselectedUser(_ pre: ManagedUser) {
        selectedUser = pre
        selectedEntryIDs = []
        showHidden = true

        let today = Self.dayKey()
        if let saved = Self.preselectedDailyPathByUser[pre.username], saved.dayKey == today {
            currentPath = saved.path
            shouldFallbackMissingOpenClaw = false
        } else {
            currentPath = ".openclaw"
            shouldFallbackMissingOpenClaw = true
            Self.preselectedDailyPathByUser[pre.username] = (today, ".openclaw")
        }
        Task { await loadDirectory() }
    }

    // MARK: - 数据加载

    private func loadDirectory() async {
        guard let user = selectedUser else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let requestedPath = currentPath
        do {
            entries = try await helperClient.listDirectory(
                username: user.username,
                relativePath: requestedPath,
                showHidden: showHidden
            )
            if requestedPath == ".openclaw" {
                shouldFallbackMissingOpenClaw = false
            }
            recordCurrentPathForToday(requestedPath)
        } catch {
            // .openclaw 不存在时，自动回退到用户 home 目录
            if requestedPath == ".openclaw" && shouldFallbackMissingOpenClaw {
                shouldFallbackMissingOpenClaw = false
                currentPath = ""
                do {
                    entries = try await helperClient.listDirectory(
                        username: user.username,
                        relativePath: "",
                        showHidden: showHidden
                    )
                    recordCurrentPathForToday("")
                    return
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 操作

    private func uploadFile() async {
        guard let user = selectedUser else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard await panel.begin() == .OK, let srcURL = panel.url else { return }
        if let error = await uploadLocalItem(srcURL: srcURL, user: user, reloadAfter: true) {
            operationError = error
        }
    }

    private func uploadDroppedItems(_ droppedURLs: [URL]) async {
        guard let user = selectedUser else { return }
        operationError = nil

        var seenPaths = Set<String>()
        let urls = droppedURLs.filter { seenPaths.insert($0.path).inserted }
        guard !urls.isEmpty else { return }

        var failures: [String] = []
        for srcURL in urls {
            if let error = await uploadLocalItem(srcURL: srcURL, user: user, reloadAfter: false) {
                failures.append("\(srcURL.lastPathComponent): \(error)")
            }
        }

        await loadDirectory()
        if !failures.isEmpty {
            let head = failures.prefix(2).joined(separator: "；")
            operationError = failures.count > 2 ? L10n.f("views.user_files_view.text_1de5d3a2", fallback: "%@；等 %@ 项失败", String(describing: head), String(describing: failures.count)) : head
        }
    }

    private func uploadLocalItem(srcURL: URL, user: ManagedUser, reloadAfter: Bool) async -> String? {
        let isDir = (try? srcURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isDir {
            return await uploadDirectory(srcURL: srcURL, user: user, reloadAfter: reloadAfter)
        }
        return await uploadSingleFile(srcURL: srcURL, user: user, reloadAfter: reloadAfter)
    }

    private func uploadSingleFile(srcURL: URL, user: ManagedUser, reloadAfter: Bool) async -> String? {
        uploadStatus = .singleUpload(name: srcURL.lastPathComponent)
        defer { uploadStatus = nil }

        let scoped = srcURL.startAccessingSecurityScopedResource()
        defer { if scoped { srcURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: srcURL) else {
            return L10n.k("views.user_files_view.localfile", fallback: "无法读取本地文件")
        }

        let destRel = currentPath.isEmpty
            ? srcURL.lastPathComponent
            : "\(currentPath)/\(srcURL.lastPathComponent)"

        do {
            try await helperClient.writeFile(username: user.username, relativePath: destRel, data: data)
            if reloadAfter { await loadDirectory() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func uploadDirectory(srcURL: URL, user: ManagedUser, reloadAfter: Bool) async -> String? {
        let baseName = srcURL.lastPathComponent
        let baseRel = currentPath.isEmpty ? baseName : "\(currentPath)/\(baseName)"

        let fm = FileManager.default
        let scoped = srcURL.startAccessingSecurityScopedResource()
        defer { if scoped { srcURL.stopAccessingSecurityScopedResource() } }
        guard let enumerator = fm.enumerator(
            at: srcURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return L10n.k("views.user_files_view.folder", fallback: "无法枚举文件夹内容")
        }

        // 先收集所有条目以便显示总数
        let allItems = enumerator.allObjects.compactMap { $0 as? URL }
        let totalFiles = allItems.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }.count

        defer { uploadStatus = nil }

        // 先创建根目录
        uploadStatus = .folderUpload(current: 0, total: totalFiles, name: baseName)
        do {
            try await helperClient.createDirectory(username: user.username, relativePath: baseRel)
        } catch {
            return String(format: L10n.k("views.user_files_view.create_directory_failed_detail", fallback: "创建目录失败：%@"), error.localizedDescription)
        }

        var failedItems: [String] = []
        var uploadedFiles = 0
        for itemURL in allItems {
            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let relativeSuffix = String(itemURL.path.dropFirst(srcURL.path.count + 1))
            let destRel = "\(baseRel)/\(relativeSuffix)"

            do {
                if isDir {
                    try await helperClient.createDirectory(username: user.username, relativePath: destRel)
                } else {
                    uploadedFiles += 1
                    uploadStatus = .folderUpload(current: uploadedFiles, total: totalFiles, name: itemURL.lastPathComponent)
                    let data = try Data(contentsOf: itemURL)
                    try await helperClient.writeFile(username: user.username, relativePath: destRel, data: data)
                }
            } catch {
                failedItems.append(relativeSuffix)
            }
        }

        if reloadAfter { await loadDirectory() }
        if !failedItems.isEmpty {
            let preview = failedItems.prefix(3).joined(separator: ", ")
            if failedItems.count > 3 {
                return String(format: L10n.k("views.user_files_view.partial_upload_failed_items_count", fallback: "部分文件上传失败：%@ 等 %d 项"), preview, failedItems.count)
            }
            return String(format: L10n.k("views.user_files_view.partial_upload_failed_items", fallback: "部分文件上传失败：%@"), preview)
        }
        return nil
    }

    private func downloadSelected() async {
        guard let user = selectedUser, let entry = selectedEntry, !entry.isDirectory else { return }
        do {
            let data = try await helperClient.readFile(username: user.username, relativePath: entry.path)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            guard await panel.begin() == .OK, let destURL = panel.url else { return }
            try data.write(to: destURL, options: .atomic)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func deleteSelected() async {
        guard let user = selectedUser, !selectedEntries.isEmpty else { return }

        let targets = topLevelDeleteTargets(from: selectedEntries)
        var failures: [String] = []

        for entry in targets {
            do {
                try await helperClient.deleteItem(username: user.username, relativePath: entry.path)
            } catch {
                failures.append("\(entry.name): \(error.localizedDescription)")
            }
        }

        selectedEntryIDs = []
        await loadDirectory()

        if !failures.isEmpty {
            let head = failures.prefix(2).joined(separator: "；")
            operationError = failures.count > 2
                ? L10n.f(
                    "views.user_files_view.delete_partial_failed_count",
                    fallback: "%@；等 %@ 项删除失败",
                    String(describing: head),
                    String(describing: failures.count)
                )
                : head
        }
    }

    private func topLevelDeleteTargets(from candidates: [FileEntry]) -> [FileEntry] {
        let sorted = candidates.sorted { lhs, rhs in
            let lCount = lhs.path.split(separator: "/").count
            let rCount = rhs.path.split(separator: "/").count
            if lCount != rCount { return lCount < rCount }
            return lhs.path < rhs.path
        }

        var chosen: [FileEntry] = []
        for entry in sorted {
            let shouldSkip = chosen.contains { parent in
                entry.path != parent.path && entry.path.hasPrefix(parent.path + "/")
            }
            if !shouldSkip {
                chosen.append(entry)
            }
        }
        return chosen
    }

    private func openTextEditor() async {
        guard let user = selectedUser, let entry = selectedEntry else { return }
        do {
            let data = try await helperClient.readFile(username: user.username, relativePath: entry.path)
            if looksLikeBinary(data) {
                operationError = L10n.f("views.user_files_view.text_92ed1d85", fallback: "「%@」是二进制文件，无法用文本编辑器打开", String(describing: entry.name))
                return
            }
            let content = String(data: data, encoding: .utf8)
                       ?? String(data: data, encoding: .isoLatin1)
                       ?? ""
            textEditState = TextEditState(entry: entry, content: content)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func saveTextEdit(entry: FileEntry, content: String) async {
        guard let user = selectedUser else { return }
        do {
            guard let data = content.data(using: .utf8) else {
                operationError = L10n.k("auto.user_files_view.failed", fallback: "内容编码失败")
                return
            }
            try await helperClient.writeFile(username: user.username, relativePath: entry.path, data: data)
            textEditState = nil
            await loadDirectory()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func createFolder() async {
        guard let user = selectedUser, !newFolderName.isEmpty else { return }
        let rel = currentPath.isEmpty ? newFolderName : "\(currentPath)/\(newFolderName)"
        do {
            try await helperClient.createDirectory(username: user.username, relativePath: rel)
            newFolderName = ""
            await loadDirectory()
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// 弹出重命名 alert 前，拆分文件名和后缀（目录不拆）
    private func beginRename(_ entry: FileEntry) {
        if entry.isDirectory {
            renameExt = ""
            renameText = entry.name
        } else {
            let ns = entry.name as NSString
            let ext = ns.pathExtension
            if ext.isEmpty {
                renameExt = ""
                renameText = entry.name
            } else {
                renameExt = ".\(ext)"
                renameText = ns.deletingPathExtension
            }
        }
        renameTarget = entry
    }

    private func openTerminalAtCurrentPath() {
        guard let user = selectedUser else { return }
        let home = "/Users/\(user.username)"
        let fullPath = currentPath.isEmpty ? home : "\(home)/\(currentPath)"
        let escaped = fullPath.replacingOccurrences(of: "'", with: "'\\''")
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: L10n.k("auto.user_files_view.file", fallback: "文件管理终端"),
            command: ["zsh", "-lc", "cd '\(escaped)' && exec /bin/zsh -l"]
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }

    private func copyCurrentPathToPasteboard() {
        copyRelativePathToPasteboard(currentPath)
    }

    private func copyEntryPathToPasteboard(_ entry: FileEntry) {
        copyRelativePathToPasteboard(entry.path)
    }

    private func copyRelativePathToPasteboard(_ relativePath: String) {
        guard let user = selectedUser else { return }
        let home = "/Users/\(user.username)"
        let fullPath: String
        if relativePath.isEmpty {
            fullPath = home
        } else if relativePath.hasPrefix("/") {
            fullPath = relativePath
        } else {
            fullPath = "\(home)/\(relativePath)"
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        _ = pb.setString(fullPath, forType: .string)
    }

    private func extractSelected() async {
        guard let user = selectedUser, let entry = selectedEntry, !entry.isDirectory else { return }
        uploadStatus = .extracting(name: entry.name)
        defer { uploadStatus = nil }
        do {
            try await helperClient.extractArchive(username: user.username, relativePath: entry.path)
            await loadDirectory()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func commitRename() async {
        guard let user = selectedUser, let target = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { renameTarget = nil; return }
        let newName = trimmed + renameExt
        guard newName != target.name else { renameTarget = nil; return }
        do {
            try await helperClient.renameItem(username: user.username,
                                              relativePath: target.path,
                                              newName: newName)
            renameTarget = nil
            selectedEntryIDs = []
            await loadDirectory()
        } catch {
            operationError = error.localizedDescription
            renameTarget = nil
        }
    }
}
