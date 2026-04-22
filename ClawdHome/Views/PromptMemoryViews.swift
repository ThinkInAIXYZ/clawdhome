import AppKit
import SwiftUI

struct PromptMemoryOverlay: View {
    private enum ActiveSurface: Equatable {
        case menu
        case prompt
        case note
    }

    let username: String?
    let currentInput: String
    let requestedQuery: String?
    let onConsumeRequest: () -> Void
    let onInsert: (String, PromptInsertionMode) -> Void

    @Environment(PromptLibraryStore.self) private var store
    @State private var activeSurface: ActiveSurface?
    @State private var query = ""
    @State private var titleDraft = ""
    @State private var tagsDraft = ""
    @State private var noteDraft = ""
    @State private var showQuickCreate = false
    @State private var suggestions: [PromptSearchResult] = []
    @State private var pendingPrompt: PromptItem?
    @State private var replaceConfirmPrompt: PromptItem?
    @State private var pendingMode: PromptInsertionMode = .append
    @State private var variableValues: [String: String] = [:]
    @State private var showReplaceConfirm = false
    @State private var bubbleDragOffset: CGSize = .zero
    @State private var bubbleDragMoved = false
    @State private var bubbleHovered = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if store.settings.floatingBubbleEnabled {
                    bubbleLayer(in: proxy)
                }

                if let activeSurface {
                    surfaceView(activeSurface, in: proxy)
                        .position(panelPosition(in: proxy, surface: activeSurface))
                        .zIndex(1003)
                        .transition(panelTransition(for: activeSurface))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(1000)
        }
        .allowsHitTesting(activeSurface != nil || !suggestions.isEmpty || store.settings.floatingBubbleEnabled)
        .zIndex(1000)
        .onExitCommand {
            handleEscape()
        }
        .onAppear {
            store.loadIfNeeded()
            noteDraft = store.quickNoteText
            updateSuggestion()
        }
        .onChange(of: currentInput) { _, _ in updateSuggestion() }
        .onChange(of: requestedQuery) { _, value in
            guard let value else { return }
            query = value
            withAnimation(panelAnimation) {
                activeSurface = .prompt
                suggestions = []
            }
            onConsumeRequest()
        }
        .onChange(of: store.quickNoteText) { _, value in
            if value != noteDraft {
                noteDraft = value
            }
        }
        .sheet(item: $pendingPrompt) { prompt in
            variableSheet(prompt: prompt)
        }
        .confirmationDialog("替换当前输入？", isPresented: $showReplaceConfirm, titleVisibility: .visible) {
            Button("替换", role: .destructive) {
                if let prompt = replaceConfirmPrompt {
                    replaceConfirmPrompt = nil
                    beginUse(prompt, mode: .replace, forceVariableSheet: true)
                }
            }
            Button("取消", role: .cancel) { replaceConfirmPrompt = nil }
        } message: {
            Text("当前输入框内容会被选中的 Prompt 替换。")
        }
    }

    private func bubble(in proxy: GeometryProxy) -> some View {
        let bubbleSize: CGFloat = 42
        let bubblePosition = bubblePosition(in: proxy, size: bubbleSize)
        return ZStack {
            if !suggestions.isEmpty, activeSurface == nil {
                suggestionList
                    .frame(width: suggestionListWidth(in: proxy))
                    .position(suggestionListPosition(from: bubblePosition, in: proxy))
                    .zIndex(1002)
                    .transition(.offset(y: 10).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }

            Circle()
                .fill(Color.accentColor.opacity(bubbleFillOpacity))
                .frame(width: bubbleSize, height: bubbleSize)
                .overlay {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(bubbleShadowOpacity), radius: bubbleShadowRadius, y: bubbleShadowYOffset)
                .contentShape(Circle())
                .help("Prompt 记忆")
                .scaleEffect(bubbleScale)
                .position(
                    x: bubblePosition.x + bubbleDragOffset.width,
                    y: bubblePosition.y + bubbleDragOffset.height
                )
                .onHover { hovering in
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        bubbleHovered = hovering
                    }
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            bubbleDragMoved = true
                            bubbleDragOffset = value.translation
                        }
                        .onEnded { value in
                            commitBubbleDrag(value: value, in: proxy)
                        }
                )
                .simultaneousGesture(
                    TapGesture().onEnded {
                        guard !bubbleDragMoved else {
                            bubbleDragMoved = false
                            return
                        }
                        query = currentInput
                        withAnimation(panelAnimation) {
                            activeSurface = activeSurface == nil ? .menu : nil
                            suggestions = []
                        }
                    }
                )
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: bubbleHovered)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: bubbleDragOffset)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: store.settings.floatingBubbleEdge)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: suggestions.map(\.id))
    }

    private func bubbleLayer(in proxy: GeometryProxy) -> some View {
        bubble(in: proxy)
    }

    private func handleEscape() {
        if pendingPrompt != nil {
            pendingPrompt = nil
            return
        }
        if showReplaceConfirm {
            showReplaceConfirm = false
            replaceConfirmPrompt = nil
            return
        }
        if activeSurface != nil || !suggestions.isEmpty {
            withAnimation(panelAnimation) {
                activeSurface = nil
                suggestions = []
            }
        }
    }

    private var panelPinned: Bool {
        store.settings.floatingPanelPinned
    }

    private func setPanelPinned(_ pinned: Bool) {
        store.updateSettings { $0.floatingPanelPinned = pinned }
    }

    private func openQuickCreate() {
        titleDraft = titleDraft.isEmpty ? inferDraftTitle() : titleDraft
        showQuickCreate = true
        if query.isEmpty {
            query = currentInput
        }
        activeSurface = .prompt
    }

    private func inferDraftTitle() -> String {
        let trimmed = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return String(trimmed.prefix(18))
    }

    @ViewBuilder
    private func surfaceView(_ surface: ActiveSurface, in proxy: GeometryProxy) -> some View {
        switch surface {
        case .menu:
            launcherMenu
                .frame(width: launcherWidth(in: proxy))
        case .prompt:
            promptPanel
                .frame(width: promptPanelWidth(in: proxy))
                .frame(maxHeight: min(620, proxy.size.height - 40))
        case .note:
            notePanel
                .frame(width: notePanelWidth(in: proxy))
                .frame(maxHeight: min(560, proxy.size.height - 40))
        }
    }

    private var promptPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Prompt 记忆")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(panelAnimation) {
                        activeSurface = .menu
                    }
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .buttonStyle(.plain)
                .help("快捷菜单")
                Button {
                    openQuickCreate()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("新增 Prompt")
                Button {
                    setPanelPinned(!panelPinned)
                } label: {
                    Image(systemName: panelPinned ? "pin.fill" : "pin")
                        .foregroundStyle(panelPinned ? Color.accentColor : Color.secondary)
                        .rotationEffect(.degrees(panelPinned ? 0 : -12))
                        .scaleEffect(panelPinned ? 1.08 : 1)
                }
                .buttonStyle(.plain)
                .help(panelPinned ? "取消固定" : "固定面板")
                .animation(.spring(response: 0.24, dampingFraction: 0.76), value: panelPinned)
                Button {
                    withAnimation(panelAnimation) {
                        activeSurface = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            TextField("搜索标题、标签、关键词或正文", text: $query)
                .textFieldStyle(.roundedBorder)

            if showQuickCreate || !currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                saveCurrentInputSection
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let results = store.search(query: query.isEmpty ? currentInput : query, limit: 30)
                    if results.isEmpty {
                        ContentUnavailableView("暂无收藏", systemImage: "text.bubble", description: Text("可以先收藏当前输入，或到 Prompt 管理页新建。"))
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        ForEach(results) { result in
                            resultRow(result)
                        }
                    }
                }
            }

            Divider()
            settingsStrip
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
    }

    private var launcherMenu: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("快捷入口")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(panelAnimation) {
                        activeSurface = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            Text("一个入口，切换 Prompt 和随手记。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                launcherItem(
                    title: "Prompt",
                    subtitle: "搜索、收藏、插入模板",
                    systemImage: "text.bubble",
                    badge: suggestions.isEmpty ? nil : "\(suggestions.count)"
                ) {
                    query = currentInput
                    withAnimation(panelAnimation) {
                        activeSurface = .prompt
                    }
                }

                launcherItem(
                    title: "随手记",
                    subtitle: noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "随手记录，关闭不丢" : notePreviewText,
                    systemImage: "note.text",
                    badge: noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "已保存"
                ) {
                    withAnimation(panelAnimation) {
                        activeSurface = .note
                    }
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.96),
                    Color(nsColor: .windowBackgroundColor).opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
    }

    private func launcherItem(
        title: String,
        subtitle: String,
        systemImage: String,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.08), in: Capsule())
                        }
                    }

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var notePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("随手记")
                        .font(.headline)
                    Text("Markdown 自动保存")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(panelAnimation) {
                        activeSurface = .menu
                    }
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .buttonStyle(.plain)
                .help("快捷菜单")
                Button {
                    withAnimation(panelAnimation) {
                        activeSurface = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            LiveMarkdownEditor(text: $noteDraft, placeholder: "支持 Markdown，输入时直接渲染。")
                .frame(minHeight: 300)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.84), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: noteDraft) { _, value in
                    store.updateQuickNote(value)
                }

            HStack {
                Text(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无内容" : "已自动保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空") {
                    noteDraft = ""
                    store.updateQuickNote("")
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
    }

    private var saveCurrentInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(showQuickCreate ? "新增 Prompt" : "收藏当前输入")
                .font(.subheadline.weight(.semibold))
            TextField("标题", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("标签/关键词，用逗号分隔", text: $tagsDraft)
                    .textFieldStyle(.roundedBorder)
                Button(showQuickCreate ? "新增" : "收藏") {
                    let bodySource = currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? query : currentInput
                    store.createPromptFromInput(title: titleDraft, body: bodySource, tagsText: tagsDraft)
                    titleDraft = ""
                    tagsDraft = ""
                    showQuickCreate = false
                    query = bodySource
                }
                .disabled(
                    titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                     query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
            }
        }
    }

    private var settingsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("默认插入", selection: Binding(
                get: { store.settings.defaultInsertionMode },
                set: { mode in store.updateSettings { $0.defaultInsertionMode = mode } }
            )) {
                Text("追加").tag(PromptInsertionMode.append)
                Text("替换").tag(PromptInsertionMode.replace)
            }
            .pickerStyle(.segmented)

            HStack {
                Toggle("相似提醒", isOn: Binding(
                    get: { store.settings.proactiveSuggestionsEnabled },
                    set: { enabled in store.updateSettings { $0.proactiveSuggestionsEnabled = enabled } }
                ))
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
    }

    private func resultRow(_ result: PromptSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if result.item.pinned {
                    Image(systemName: "pin.fill").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(result.score * 100))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !result.item.summary.isEmpty {
                Text(result.item.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(result.item.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                ForEach(result.item.tags.prefix(4), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Spacer()
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.item.body, forType: .string)
                    store.recordUse(prompt: result.item, action: .copy, query: query, shrimpUsername: username)
                }
                Button("追加") { beginUse(result.item, mode: .append) }
                Button("替换") {
                    replaceConfirmPrompt = result.item
                    pendingMode = .replace
                    showReplaceConfirm = true
                }
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, result in
                suggestionRow(result, index: index)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }

    private func suggestionRow(_ result: PromptSearchResult, index: Int) -> some View {
        HStack(spacing: 8) {
            Button {
                beginUse(result.item, mode: .append)
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 22, height: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.item.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(compactSuggestionSubtitle(for: result))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text("用")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.10), in: Capsule())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                store.dismissSuggestion(prompt: result.item, query: currentInput)
                suggestions.removeAll { $0.id == result.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .transition(.offset(y: 8).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .top)))
        .animation(.spring(response: 0.28, dampingFraction: 0.84).delay(Double(index) * 0.03), value: suggestions.map(\.id))
    }

    private func variableSheet(prompt: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("填充变量")
                .font(.headline)
            Text(prompt.title)
                .foregroundStyle(.secondary)
            ForEach(store.variables(in: prompt), id: \.self) { key in
                TextField(key, text: Binding(
                    get: { variableValues[key, default: ""] },
                    set: { variableValues[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("取消") { pendingPrompt = nil }
                Button(pendingMode == .replace ? "替换" : "追加") {
                    let body = store.renderedBody(for: prompt, values: variableValues)
                    onInsert(body, pendingMode)
                    store.recordUse(prompt: prompt, action: pendingMode == .replace ? .replace : .append, query: query, shrimpUsername: username)
                    pendingPrompt = nil
                    withAnimation(panelAnimation) {
                        if !panelPinned {
                            activeSurface = nil
                        }
                        suggestions = []
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func beginUse(_ prompt: PromptItem, mode: PromptInsertionMode, forceVariableSheet: Bool = false) {
        pendingMode = mode
        variableValues = defaultVariableValues()
        let variables = store.variables(in: prompt)
        if forceVariableSheet || !variables.isEmpty {
            pendingPrompt = prompt
            return
        }
        onInsert(prompt.body, mode)
        store.recordUse(prompt: prompt, action: mode == .replace ? .replace : .append, query: query.isEmpty ? currentInput : query, shrimpUsername: username)
        withAnimation(panelAnimation) {
            if !panelPinned {
                activeSurface = nil
            }
            suggestions = []
        }
    }

    private func updateSuggestion() {
        guard activeSurface == nil else { return }
        let trimmed = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let minimumLength = requiresShorterTrigger(for: trimmed) ? 2 : 4
        guard trimmed.count >= minimumLength else {
            withAnimation(.easeOut(duration: 0.18)) {
                suggestions = []
            }
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            suggestions = store.suggestions(for: trimmed, limit: 3)
        }
    }

    private func defaultVariableValues() -> [String: String] {
        [
            "input": currentInput,
            "clipboard": NSPasteboard.general.string(forType: .string) ?? "",
            "date": DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none),
            "selectedText": ""
        ]
    }

    private func bubblePosition(in proxy: GeometryProxy, size: CGFloat) -> CGPoint {
        let xInset = size / 2 + 10
        let y = max(48, min(proxy.size.height - 48, proxy.size.height * store.settings.floatingBubbleYRatio))
        let x = store.settings.floatingBubbleEdge == .leading ? xInset : proxy.size.width - xInset
        return CGPoint(x: x, y: y)
    }

    private func suggestionListPosition(from bubblePosition: CGPoint, in proxy: GeometryProxy) -> CGPoint {
        let suggestionWidth = suggestionListWidth(in: proxy)
        let rowHeight: CGFloat = 44
        let suggestionHeight = CGFloat(max(suggestions.count, 1)) * rowHeight + 14
        let edgeMargin: CGFloat = 12
        let proposedX = bubblePosition.x
        let proposedY = bubblePosition.y - 42 - suggestionHeight / 2
        let clampedX = min(max(proposedX, suggestionWidth / 2 + edgeMargin), proxy.size.width - suggestionWidth / 2 - edgeMargin)
        let clampedY = min(max(proposedY, suggestionHeight / 2 + edgeMargin), proxy.size.height - suggestionHeight / 2 - edgeMargin)
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func suggestionListWidth(in proxy: GeometryProxy) -> CGFloat {
        min(240, max(180, proxy.size.width * 0.25))
    }

    private func compactSuggestionSubtitle(for result: PromptSearchResult) -> String {
        if let firstField = result.matchedFields.first {
            return "匹配 \(firstField)"
        }
        return "可复用"
    }

    private func requiresShorterTrigger(for text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }

    private func commitBubbleDrag(value: DragGesture.Value, in proxy: GeometryProxy) {
        let base = bubblePosition(in: proxy, size: 42)
        let finalX = base.x + value.translation.width
        let finalY = base.y + value.translation.height
        let clampedY = min(max(finalY, 48), proxy.size.height - 48)
        let snappedEdge: PromptLibrarySettings.FloatingBubbleEdge = finalX < proxy.size.width / 2 ? .leading : .trailing
        let ratio = min(0.92, max(0.08, clampedY / max(proxy.size.height, 1)))

        bubbleDragOffset = .zero
        bubbleDragMoved = abs(value.translation.width) > 3 || abs(value.translation.height) > 3
        store.updateSettings {
            $0.floatingBubbleEdge = snappedEdge
            $0.floatingBubbleYRatio = ratio
        }
    }

    private func promptPanelWidth(in proxy: GeometryProxy) -> CGFloat {
        min(520, max(360, proxy.size.width * 0.42))
    }

    private func launcherWidth(in proxy: GeometryProxy) -> CGFloat {
        min(280, max(220, proxy.size.width * 0.22))
    }

    private func notePanelWidth(in proxy: GeometryProxy) -> CGFloat {
        min(420, max(320, proxy.size.width * 0.32))
    }

    private func panelPosition(in proxy: GeometryProxy, surface: ActiveSurface) -> CGPoint {
        let width: CGFloat
        let panelHeight: CGFloat
        switch surface {
        case .menu:
            width = launcherWidth(in: proxy)
            panelHeight = 212
        case .prompt:
            width = promptPanelWidth(in: proxy)
            panelHeight = min(620, proxy.size.height - 40)
        case .note:
            width = notePanelWidth(in: proxy)
            panelHeight = min(560, proxy.size.height - 40)
        }
        let halfWidth = width / 2
        let halfHeight = panelHeight / 2
        let bubbleCenter = bubblePosition(in: proxy, size: 42)
        let edgePadding: CGFloat = 12
        let gapFromBubble: CGFloat = 18
        let bubbleRadius: CGFloat = 21
        let y = min(max(bubbleCenter.y, halfHeight + edgePadding), proxy.size.height - halfHeight - edgePadding)
        let proposedX: CGFloat
        if store.settings.floatingBubbleEdge == .trailing {
            proposedX = bubbleCenter.x - bubbleRadius - gapFromBubble - halfWidth
        } else {
            proposedX = bubbleCenter.x + bubbleRadius + gapFromBubble + halfWidth
        }
        let x = min(max(proposedX, halfWidth + edgePadding), proxy.size.width - halfWidth - edgePadding)
        return CGPoint(x: x, y: y)
    }

    private func panelTransition(for surface: ActiveSurface) -> AnyTransition {
        let anchor: UnitPoint = store.settings.floatingBubbleEdge == .trailing ? .trailing : .leading
        let edge: Edge = store.settings.floatingBubbleEdge == .trailing ? .trailing : .leading
        let insertionScale: CGFloat = surface == .menu ? 0.94 : 0.97
        return .asymmetric(
            insertion: .move(edge: edge)
                .combined(with: .opacity)
                .combined(with: .scale(scale: insertionScale, anchor: anchor)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: anchor))
        )
    }

    private var bubbleScale: CGFloat {
        if bubbleDragOffset != .zero { return 1.08 }
        if bubbleHovered || activeSurface != nil { return 1.04 }
        return 1
    }

    private var bubbleFillOpacity: Double {
        if bubbleDragOffset != .zero { return 0.96 }
        if activeSurface != nil || bubbleHovered { return 0.92 }
        return 0.82
    }

    private var bubbleShadowOpacity: Double {
        if bubbleDragOffset != .zero { return 0.24 }
        if bubbleHovered || activeSurface != nil { return 0.2 }
        return 0.16
    }

    private var bubbleShadowRadius: CGFloat {
        bubbleDragOffset != .zero ? 16 : (bubbleHovered || activeSurface != nil ? 12 : 9)
    }

    private var bubbleShadowYOffset: CGFloat {
        bubbleDragOffset != .zero ? 8 : 4
    }

    private var panelAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.82)
    }

    private var notePreviewText: String {
        let trimmed = noteDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !trimmed.isEmpty else { return "随手记录，关闭不丢" }
        return String(trimmed.prefix(28))
    }
}

private struct LiveMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, placeholder: placeholder)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = PlaceholderTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.placeholder = placeholder

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.apply(to: textView, string: text, preserveSelection: false)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.placeholder = placeholder
        if context.coordinator.isApplying { return }
        if textView.string != text {
            context.coordinator.apply(to: textView, string: text, preserveSelection: true)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        private let placeholder: String
        weak var textView: PlaceholderTextView?
        var isApplying = false

        init(text: Binding<String>, placeholder: String) {
            _text = text
            self.placeholder = placeholder
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            apply(to: textView, string: textView.string, preserveSelection: true)
        }

        func apply(to textView: PlaceholderTextView, string: String, preserveSelection: Bool) {
            isApplying = true
            let selectedRanges = preserveSelection ? textView.selectedRanges : []
            textView.textStorage?.setAttributedString(Self.makeAttributedString(from: string))
            if preserveSelection, !selectedRanges.isEmpty {
                textView.selectedRanges = selectedRanges
            }
            textView.placeholder = placeholder
            textView.needsDisplay = true
            isApplying = false
        }

        private static func makeAttributedString(from text: String) -> NSAttributedString {
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: baseAttributes
            )

            let fullRange = NSRange(location: 0, length: attributed.length)
            let nsText = text as NSString

            applyBlockStyles(to: attributed, text: nsText)
            applyInlinePatterns(to: attributed, text: nsText, range: fullRange)
            return attributed
        }

        private static var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        }

        private static func applyBlockStyles(to attributed: NSMutableAttributedString, text: NSString) {
            let source = text as String
            let lines = source.components(separatedBy: .newlines)
            var location = 0
            var inCodeBlock = false

            for line in lines {
                let range = NSRange(location: location, length: line.count)
                defer { location += line.count + 1 }

                if line.hasPrefix("```") {
                    inCodeBlock.toggle()
                    attributed.addAttributes(codeBlockAttributes, range: range)
                    continue
                }

                if inCodeBlock {
                    attributed.addAttributes(codeBlockAttributes, range: range)
                    continue
                }

                if line.hasPrefix("# ") {
                    attributed.addAttributes(headerAttributes(size: 22), range: range)
                } else if line.hasPrefix("## ") {
                    attributed.addAttributes(headerAttributes(size: 19), range: range)
                } else if line.hasPrefix("### ") {
                    attributed.addAttributes(headerAttributes(size: 17), range: range)
                } else if line.hasPrefix("> ") {
                    attributed.addAttributes(quoteAttributes, range: range)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("1. ") {
                    attributed.addAttributes(listAttributes, range: range)
                }
            }
        }

        private static func applyInlinePatterns(to attributed: NSMutableAttributedString, text: NSString, range: NSRange) {
            let source = text as String
            let patterns: [(String, [NSAttributedString.Key: Any])] = [
                (#"\*\*(.+?)\*\*"#, [.font: NSFont.systemFont(ofSize: 14, weight: .bold)]),
                (#"`([^`]+)`"#, [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10)
                ]),
                (#"\[(.+?)\]\((.+?)\)"#, [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ])
            ]

            for (pattern, attrs) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let matches = regex.matches(in: source, range: range)
                for match in matches {
                    attributed.addAttributes(attrs, range: match.range)
                    if match.numberOfRanges > 0 {
                        attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range(at: 0))
                    }
                    if match.numberOfRanges > 1 {
                        attributed.addAttributes(attrs, range: match.range(at: 1))
                        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: match.range(at: 1))
                    }
                }
            }
        }

        private static func headerAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        }

        private static var quoteAttributes: [NSAttributedString.Key: Any] {
            [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 14, weight: .regular)
            ]
        }

        private static var listAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        }

        private static var codeBlockAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.08),
                .foregroundColor: NSColor.labelColor
            ]
        }
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }
        let rect = NSRect(
            x: textContainerInset.width + 3,
            y: textContainerInset.height + 1,
            width: bounds.width - textContainerInset.width * 2,
            height: 22
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        placeholder.draw(in: rect, withAttributes: attributes)
    }
}

struct PromptLibraryView: View {
    @Environment(PromptLibraryStore.self) private var store
    @State private var title = ""
    @State private var bodyText = ""
    @State private var tags = ""
    @State private var selectedPromptId: UUID?
    @State private var selectedFilter: PromptLibraryFilter = .all
    @State private var sortMode: PromptLibrarySort = .smart
    @State private var isPinned = false
    @State private var isEnabled = true
    @State private var isSensitive = false
    @State private var insertionMode: PromptInsertionMode = .append

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Prompt 管理")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        clearEditor()
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                }
                TextField("搜索标题、标签、关键词或正文", text: Binding(
                    get: { store.searchText },
                    set: { store.searchText = $0 }
                ))
                .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    statRow(title: "总数", value: "\(store.prompts.count)")
                    statRow(title: "置顶", value: "\(store.prompts.filter(\.pinned).count)")
                    statRow(title: "最近使用", value: "\(store.prompts.filter { $0.lastUsedAt != nil }.count)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                List(selection: $selectedFilter) {
                    Section("浏览") {
                        filterRow(.all, systemImage: "tray.full", count: store.prompts.count)
                        filterRow(.pinned, systemImage: "pin.fill", count: store.prompts.filter(\.pinned).count)
                        filterRow(.recent, systemImage: "clock.arrow.circlepath", count: store.prompts.filter { $0.lastUsedAt != nil }.count)
                        filterRow(.unused, systemImage: "circle.dashed", count: store.prompts.filter { $0.useCount == 0 }.count)
                    }

                    if !availableTags.isEmpty {
                        Section("标签") {
                            ForEach(availableTags, id: \.name) { tag in
                                HStack {
                                    Label(tag.name, systemImage: "number")
                                    Spacer()
                                    Text("\(tag.count)")
                                        .foregroundStyle(.secondary)
                                }
                                .tag(PromptLibraryFilter.tag(tag.name))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 220)
            }
            .padding(16)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(filterTitle)
                            .font(.headline)
                        Text(resultSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("排序", selection: $sortMode) {
                        ForEach(PromptLibrarySort.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }

                if displayedPrompts.isEmpty {
                    ContentUnavailableView(
                        "没有匹配的 Prompt",
                        systemImage: "magnifyingglass",
                        description: Text("换一个关键词，或者在右侧新建一条 Prompt。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedPromptId) {
                        if sortMode == .smart && normalizedSearchText.isEmpty {
                            let pinnedItems = displayedPrompts.filter(\.pinned)
                            let regularItems = displayedPrompts.filter { !$0.pinned }
                            if !pinnedItems.isEmpty {
                                Section("置顶") {
                                    ForEach(pinnedItems) { prompt in
                                        promptRow(prompt)
                                            .tag(prompt.id)
                                    }
                                }
                            }
                            if !regularItems.isEmpty {
                                Section(pinnedItems.isEmpty ? filterTitle : "全部结果") {
                                    ForEach(regularItems) { prompt in
                                        promptRow(prompt)
                                            .tag(prompt.id)
                                    }
                                }
                            }
                        } else {
                            ForEach(displayedPrompts) { prompt in
                                promptRow(prompt)
                                    .tag(prompt.id)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(minWidth: 340)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedPromptId == nil ? "新建 Prompt" : "编辑 Prompt")
                            .font(.headline)
                        Text(detailSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedPromptId != nil {
                        Button("删除", role: .destructive) {
                            if let selectedPromptId {
                                store.deletePrompt(id: selectedPromptId)
                                clearEditor()
                            }
                        }
                    }
                }

                Form {
                    Section("基本信息") {
                        TextField("标题", text: $title)
                        TextField("标签/关键词，用逗号分隔", text: $tags)
                        Picker("默认插入", selection: $insertionMode) {
                            Text("追加").tag(PromptInsertionMode.append)
                            Text("替换").tag(PromptInsertionMode.replace)
                        }
                    }

                    Section("状态") {
                        Toggle("启用此 Prompt", isOn: $isEnabled)
                        Toggle("置顶", isOn: $isPinned)
                    }

                    Section("正文") {
                        TextEditor(text: $bodyText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 260)
                    }

                    Section("库设置") {
                        Toggle("相似提醒", isOn: Binding(
                            get: { store.settings.proactiveSuggestionsEnabled },
                            set: { value in store.updateSettings { $0.proactiveSuggestionsEnabled = value } }
                        ))
                    }
                }
                .formStyle(.grouped)

                HStack {
                    if let error = store.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("保存") { saveEditor() }
                        .buttonStyle(.borderedProminent)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(minWidth: 420, idealWidth: 460)
        }
        .navigationTitle("Prompt")
        .onAppear {
            store.loadIfNeeded()
            syncSelectionWithVisibleResults()
        }
        .onChange(of: selectedPromptId) { _, id in
            guard let id, let prompt = store.prompts.first(where: { $0.id == id }) else { return }
            loadEditor(prompt)
        }
        .onChange(of: store.searchText) { _, _ in
            syncSelectionWithVisibleResults()
        }
        .onChange(of: selectedFilter) { _, _ in
            syncSelectionWithVisibleResults()
        }
        .onChange(of: sortMode) { _, _ in
            syncSelectionWithVisibleResults()
        }
        .onChange(of: store.prompts) { _, _ in
            syncSelectionWithVisibleResults()
        }
    }

    private func saveEditor() {
        let parsedTags = tags
            .split { $0 == "," || $0 == "，" || $0 == "#" || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let selectedPromptId, let existing = store.prompts.first(where: { $0.id == selectedPromptId }) {
            var next = existing
            next.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            next.body = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            next.summary = String(next.body.prefix(160))
            next.tags = parsedTags
            next.triggerKeywords = parsedTags
            next.insertionModeDefault = insertionMode
            next.enabled = isEnabled
            next.pinned = isPinned
            next.sensitive = isSensitive
            store.savePrompt(next)
        } else {
            let newItem = PromptItem(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: String(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)),
                tags: parsedTags,
                triggerKeywords: parsedTags,
                insertionModeDefault: insertionMode,
                enabled: isEnabled,
                pinned: isPinned,
                sensitive: isSensitive
            )
            store.savePrompt(newItem)
            selectedPromptId = newItem.id
        }
    }

    private func clearEditor() {
        selectedPromptId = nil
        title = ""
        bodyText = ""
        tags = ""
        isPinned = false
        isEnabled = true
        isSensitive = false
        insertionMode = store.settings.defaultInsertionMode
    }

    private func loadEditor(_ prompt: PromptItem) {
        title = prompt.title
        bodyText = prompt.body
        tags = (prompt.tags + prompt.triggerKeywords.filter { !prompt.tags.contains($0) }).joined(separator: ", ")
        isPinned = prompt.pinned
        isEnabled = prompt.enabled
        isSensitive = prompt.sensitive
        insertionMode = prompt.insertionModeDefault
    }

    private var normalizedSearchText: String {
        PromptMemorySearch.normalize(store.searchText)
    }

    private var availableTags: [(name: String, count: Int)] {
        Dictionary(grouping: store.prompts.flatMap(\.tags), by: { $0 })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private var displayedPrompts: [PromptItem] {
        store.prompts
            .filter(matchesSearch)
            .filter(matchesFilter)
            .sorted(by: sortPrompts)
    }

    private var filterTitle: String {
        selectedFilter.title
    }

    private var resultSummary: String {
        if normalizedSearchText.isEmpty {
            return "共 \(displayedPrompts.count) 条"
        }
        return "搜索到 \(displayedPrompts.count) 条匹配结果"
    }

    private var detailSubtitle: String {
        guard let selectedPromptId,
              let prompt = store.prompts.first(where: { $0.id == selectedPromptId }) else {
            return "填写标题、标签和正文后保存到库中。"
        }
        let lastUsed = prompt.lastUsedAt.map(relativeDateString) ?? "尚未使用"
        return "使用 \(prompt.useCount) 次 · 最近使用 \(lastUsed)"
    }

    @ViewBuilder
    private func filterRow(_ filter: PromptLibraryFilter, systemImage: String, count: Int) -> some View {
        HStack {
            Label(filter.title, systemImage: systemImage)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
        }
        .tag(filter)
    }

    @ViewBuilder
    private func promptRow(_ prompt: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(prompt.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if prompt.pinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.secondary)
                }
                if !prompt.enabled {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                }
                if prompt.sensitive {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(prompt.useCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(prompt.summary.isEmpty ? prompt.body : prompt.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                ForEach(prompt.tags.prefix(3), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Spacer()
                Text(sourceLabel(prompt.source))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let lastUsedAt = prompt.lastUsedAt {
                    Text(relativeDateString(lastUsedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
        }
    }

    private func matchesSearch(_ prompt: PromptItem) -> Bool {
        guard !normalizedSearchText.isEmpty else { return true }
        let fields = [
            prompt.title,
            prompt.summary,
            prompt.body,
            prompt.tags.joined(separator: " "),
            prompt.triggerKeywords.joined(separator: " ")
        ]
        return fields
            .map(PromptMemorySearch.normalize)
            .contains { $0.contains(normalizedSearchText) }
    }

    private func matchesFilter(_ prompt: PromptItem) -> Bool {
        switch selectedFilter {
        case .all:
            return true
        case .pinned:
            return prompt.pinned
        case .recent:
            return prompt.lastUsedAt != nil
        case .unused:
            return prompt.useCount == 0
        case .tag(let tag):
            return prompt.tags.contains(tag) || prompt.triggerKeywords.contains(tag)
        }
    }

    private func sortPrompts(_ lhs: PromptItem, _ rhs: PromptItem) -> Bool {
        switch sortMode {
        case .smart:
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
            }
            if lhs.useCount != rhs.useCount { return lhs.useCount > rhs.useCount }
            return lhs.updatedAt > rhs.updatedAt
        case .recent:
            let left = lhs.lastUsedAt ?? lhs.updatedAt
            let right = rhs.lastUsedAt ?? rhs.updatedAt
            if left != right { return left > right }
            return lhs.updatedAt > rhs.updatedAt
        case .title:
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case .mostUsed:
            if lhs.useCount != rhs.useCount { return lhs.useCount > rhs.useCount }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func syncSelectionWithVisibleResults() {
        if case .tag(let tag) = selectedFilter,
           !availableTags.contains(where: { $0.name == tag }) {
            selectedFilter = .all
        }
        guard !displayedPrompts.isEmpty else {
            if selectedPromptId != nil {
                clearEditor()
            }
            return
        }
        guard let selectedPromptId,
              displayedPrompts.contains(where: { $0.id == selectedPromptId }) else {
            self.selectedPromptId = displayedPrompts.first?.id
            if let prompt = displayedPrompts.first {
                loadEditor(prompt)
            }
            return
        }
        if let prompt = store.prompts.first(where: { $0.id == selectedPromptId }) {
            loadEditor(prompt)
        }
    }

    private func sourceLabel(_ source: PromptSource) -> String {
        switch source {
        case .userCreated:
            return "手动创建"
        case .imported:
            return "导入"
        case .savedFromInput:
            return "来自输入"
        }
    }

    private func relativeDateString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private enum PromptLibraryFilter: Hashable {
    case all
    case pinned
    case recent
    case unused
    case tag(String)

    var title: String {
        switch self {
        case .all:
            return "全部 Prompt"
        case .pinned:
            return "置顶"
        case .recent:
            return "最近使用"
        case .unused:
            return "未使用"
        case .tag(let tag):
            return "#\(tag)"
        }
    }
}

private enum PromptLibrarySort: String, CaseIterable, Identifiable {
    case smart
    case recent
    case title
    case mostUsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart:
            return "推荐"
        case .recent:
            return "最近"
        case .title:
            return "标题"
        case .mostUsed:
            return "常用"
        }
    }
}
