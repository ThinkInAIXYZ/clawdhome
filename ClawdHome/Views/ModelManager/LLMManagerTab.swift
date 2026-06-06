// ClawdHome/Views/ModelManager/LLMManagerTab.swift
// 全局模型池：按 Provider 类型聚合展示已选模型，采用 ClawdHome 统一设计语言自适应改版

import SwiftUI

struct LLMManagerTab: View {
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAddSheet = false
    @State private var editingProvider: ProviderTemplate? = nil
    @State private var deleteConfirmId: UUID? = nil
    @State private var configuredSecretKeys: Set<String> = []
    @State private var searchText: String = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var hoveredCardId: UUID? = nil
    
    // 双视图状态：0 账户管理，1 排序与默认
    @State private var viewMode = 0

    private var deleteTarget: ProviderTemplate? {
        guard let id = deleteConfirmId else { return nil }
        return modelStore.providers.first { $0.id == id }
    }

    /// 按 group 排序的内置顺序：先内置（按 builtInModelGroups 顺序），再 custom，再其它未知 ID
    private var groupedProviders: [(groupId: String, displayName: String, providers: [ProviderTemplate])] {
        let providers = modelStore.providers
        let knownOrder: [String] = builtInModelGroups.map(\.id)
        let groupIds = Array(NSOrderedSet(array: providers.map(\.providerGroupId))) as? [String] ?? []
        let sortedIds = groupIds.sorted { a, b in
            let ai = knownOrder.firstIndex(of: a) ?? Int.max
            let bi = knownOrder.firstIndex(of: b) ?? Int.max
            if ai == bi { return a < b }
            return ai < bi
        }
        return sortedIds.map { gid in
            let bucket = providers.filter { $0.providerGroupId == gid }
            let displayName = bucket.first?.providerDisplayName
                ?? builtInModelGroups.first(where: { $0.id == gid })?.provider
                ?? gid
            return (gid, displayName, filterProviders(bucket))
        }.filter { !$0.providers.isEmpty }
    }

    /// 搜索过滤：匹配别名 / customBaseURL / 任一 modelId
    private func filterProviders(_ providers: [ProviderTemplate]) -> [ProviderTemplate] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return providers }
        return providers.filter { p in
            if p.name.lowercased().contains(q) { return true }
            if let url = p.customBaseURL?.lowercased(), url.contains(q) { return true }
            if p.modelIds.contains(where: { $0.lowercased().contains(q) }) { return true }
            return false
        }
    }

    private var hasAnyResults: Bool {
        groupedProviders.contains { !$0.providers.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showAddSheet) {
            AddProviderModelSheet()
        }
        .sheet(item: $editingProvider) { provider in
            AddProviderModelSheet(editing: provider)
        }
        .task { refreshConfiguredSecrets() }
        .onChange(of: modelStore.revision) { _, _ in
            refreshConfiguredSecrets()
        }
        .alert(
            L10n.f("views.model_manager.llmmanager_tab.delete_confirm", fallback: "删除「%@」？", deleteTarget?.name ?? ""),
            isPresented: Binding(
                get: { deleteConfirmId != nil },
                set: { if !$0 { deleteConfirmId = nil } }
            )
        ) {
            Button(L10n.k("views.model_manager.llmmanager_tab.delete", fallback: "删除"), role: .destructive) {
                if let id = deleteConfirmId { modelStore.removeProvider(id: id) }
                deleteConfirmId = nil
            }
            Button(L10n.k("views.model_manager.llmmanager_tab.cancel", fallback: "取消"), role: .cancel) { deleteConfirmId = nil }
        } message: {
            Text(L10n.k("views.model_manager.llmmanager_tab.global_model_pool_account", fallback: "将从全局模型池中移除该账户下所有模型型号。"))
        }
    }

    // MARK: - 顶部 Header

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("views.model_manager.llmmanager_tab.global_model_pool", fallback: "全局模型池"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                    
                    Text(L10n.k("views.model_manager.llmmanager_tab.configuration_account", fallback: "集中管理您的服务商密钥，为每只“虾”绑定专属的智能大脑。"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // 双分栏控制切换器
                if !modelStore.providers.isEmpty {
                    Picker("", selection: $viewMode) {
                        Text(L10n.k("views.model_manager.llmmanager_tab.view_accounts", fallback: "账户管理")).tag(0)
                        Text(L10n.k("views.model_manager.llmmanager_tab.view_sorting", fallback: "排序与默认")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }
            
            // 搜索框 - 仅在账户管理视图下显示
            if !modelStore.providers.isEmpty && viewMode == 0 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13, weight: .medium))
                    
                    TextField(
                        L10n.k("views.model_manager.llmmanager_tab.search_placeholder", fallback: "搜索别名、URL 或模型 ID…"),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.15), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.01), radius: 2, y: 1)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if modelStore.providers.isEmpty {
            ContentUnavailableView {
                Label(L10n.k("views.model_manager.llmmanager_tab.configuration", fallback: "尚未配置模型"), systemImage: "cpu")
            } description: {
                Text(L10n.k("models.llm_manager.empty.add_model_desc",
                            fallback: "点击「添加模型」，选择 Provider 并一次勾选多个模型。"))
            } actions: {
                Button(L10n.k("views.model_manager.llmmanager_tab.add_model", fallback: "添加模型")) {
                    showAddSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewMode == 1 {
            // 平铺排序与默认模型列表视图
            sortingAndDefaultView
        } else if !hasAnyResults {
            ContentUnavailableView {
                Label(L10n.k("views.model_manager.llmmanager_tab.no_results", fallback: "无匹配结果"), systemImage: "magnifyingglass")
            } description: {
                Text(L10n.k("views.model_manager.llmmanager_tab.no_results_hint", fallback: "换个关键词或清空搜索框"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(groupedProviders, id: \.groupId) { section in
                        groupSection(groupId: section.groupId,
                                     displayName: section.displayName,
                                     providers: section.providers)
                    }
                    Color.clear.frame(height: 60) // 给浮动按钮让位
                }
                .padding(24)
            }
            .overlay(alignment: .bottomTrailing) {
                // 升级为极其优雅的悬浮玻璃 pill 按钮
                Button {
                    showAddSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                        Text(L10n.k("views.model_manager.llmmanager_tab.add_model", fallback: "添加模型"))
                            .font(.system(size: 13, weight: .bold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.gradient)
                    )
                    .foregroundStyle(.white)
                    .shadow(color: Color.accentColor.opacity(colorScheme == .dark ? 0.35 : 0.22), radius: 10, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .padding(24)
            }
        }
    }

    // MARK: - 模型排序与系统默认平铺控制视图

    @ViewBuilder
    private var sortingAndDefaultView: some View {
        let activeModels = modelStore.sortedActiveModels
        
        VStack(alignment: .leading, spacing: 0) {
            // 说明提示条 - 高质感小卡片
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.blue)
                    .font(.system(size: 13))
                
                Text(L10n.k("views.model_manager.llmmanager_tab.sorting_hint", fallback: "上下拖拽调整已启用模型的展示优先级；点击“星标”将其设为全局默认模型。"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(colorScheme == .dark ? 0.08 : 0.05))
            .cornerRadius(8)
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 12)
            
            if activeModels.isEmpty {
                ContentUnavailableView {
                    Label(L10n.k("views.model_manager.llmmanager_tab.no_active_models", fallback: "无启用的模型"), systemImage: "star.slash")
                } description: {
                    Text(L10n.k("views.model_manager.llmmanager_tab.no_active_models_desc", fallback: "请先在「账户管理」中添加账户并勾选需要启用的模型。"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(activeModels) { item in
                        activeModelRow(item)
                    }
                    .onMove { indices, newOffset in
                        modelStore.moveActiveModel(from: indices, to: newOffset)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
    }

    private func activeModelRow(_ item: ActiveModelEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 20)

            providerBadge(for: item.provider.providerGroupId)
            activeModelTitle(item)
            Spacer()
            defaultModelControl(for: item)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Color.secondary.opacity(colorScheme == .dark ? 0.03 : 0.02))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(item.isDefault ? Color.orange.opacity(0.2) : Color.primary.opacity(0.04), lineWidth: 1)
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func providerBadge(for providerGroupId: String) -> some View {
        let theme = providerTheme(for: providerGroupId)

        return ZStack {
            Circle()
                .fill(theme.mainColor.opacity(0.1))
                .frame(width: 28, height: 28)
            Image(systemName: providerIconName(for: providerGroupId))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.mainColor)
        }
    }

    private func activeModelTitle(_ item: ActiveModelEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.modelId)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)

            Text(item.provider.displayNameWithAlias)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func defaultModelControl(for item: ActiveModelEntry) -> some View {
        if item.isDefault {
            defaultModelBadge
        } else {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    modelStore.setDefaultModel(key: item.id)
                }
            } label: {
                setDefaultLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var defaultModelBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.orange)
            Text(L10n.k("views.model_manager.llmmanager_tab.system_default", fallback: "系统默认"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.24), lineWidth: 0.7)
        )
    }

    private var setDefaultLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "star")
                .font(.system(size: 9))
            Text(L10n.k("views.model_manager.llmmanager_tab.set_as_default", fallback: "设为默认"))
                .font(.system(size: 10))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.7)
        )
    }

    private func providerTheme(for providerGroupId: String) -> DesignSystem.GradientTheme {
        switch providerGroupId.lowercased() {
        case "kimi": return .emerald
        case "openai": return .teal
        case "anthropic": return .purple
        case "qiniu": return .orange
        case "custom": return .blue
        default: return .blue
        }
    }

    private func providerIconName(for providerGroupId: String) -> String {
        switch providerGroupId.lowercased() {
        case "kimi": return "bolt.shield.fill"
        case "openai": return "cpu.fill"
        case "anthropic": return "brain.head.profile"
        case "qiniu": return "cloud.fill"
        case "custom": return "gearshape.2.fill"
        default: return "cpu"
        }
    }

    // MARK: - Provider 分组 Section

    @ViewBuilder
    private func groupSection(groupId: String, displayName: String, providers: [ProviderTemplate]) -> some View {
        let isCollapsed = collapsedGroups.contains(groupId)
        let totalModels = providers.reduce(0) { $0 + $1.modelIds.count }

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        if isCollapsed { collapsedGroups.remove(groupId) }
                        else { collapsedGroups.insert(groupId) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        
                        Text(displayName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                        
                        Text(L10n.f(
                            "views.model_manager.llmmanager_tab.collapsed_summary",
                            fallback: "%1$d 个账号 · %2$d 个模型",
                            providers.count,
                            totalModels
                        ))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()
            }

            if !isCollapsed {
                // 采用响应式自适应网格，在界面拉宽时可以双列排布，最大化利用空间
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16)], spacing: 16) {
                    ForEach(providers) { provider in
                        providerCard(provider)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    // MARK: - Provider 卡片 (自适应双轨 UI 设计)

    @ViewBuilder
    private func providerCard(_ provider: ProviderTemplate) -> some View {
        let isCustom = provider.providerGroupId == "custom"
        let secretKey = "\(provider.providerGroupId):\(provider.name)"
        let hasKey = configuredSecretKeys.contains(secretKey)
        
        // 绑定业务域情感渐变主题
        let cardTheme: DesignSystem.GradientTheme = {
            switch provider.providerGroupId.lowercased() {
            case "kimi": return .emerald
            case "openai": return .teal
            case "anthropic": return .purple
            case "qiniu": return .orange
            case "custom": return .blue
            default: return .blue
            }
        }()
        
        // 自适应系统图标
        let iconName: String = {
            switch provider.providerGroupId.lowercased() {
            case "kimi": return "bolt.shield.fill"
            case "openai": return "cpu.fill"
            case "anthropic": return "brain.head.profile"
            case "qiniu": return "cloud.fill"
            case "custom": return "gearshape.2.fill"
            default: return "cpu"
            }
        }()

        VStack(alignment: .leading, spacing: 0) {
            
            // 头部：图标、别名与状态发光徽章
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(hasKey ? cardTheme.mainColor.opacity(0.1) : Color.secondary.opacity(0.06))
                        .frame(width: 38, height: 38)
                    
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(hasKey ? cardTheme.mainColor : .secondary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.name.isEmpty ? provider.providerDisplayName : provider.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    // 用呼吸状态指示灯呈现凭据状态
                    PremiumStatusBadge(style: hasKey ? .ready : .planned)
                }
                
                Spacer()
                
                // 操作按钮组 - 悬停时淡入，平时隐藏，极大净化静态视觉噪音
                HStack(spacing: 8) {
                    Button { editingProvider = provider } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22, height: 22)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.k("views.model_manager.llmmanager_tab.edit_models", fallback: "编辑型号"))

                    Button { deleteConfirmId = provider.id } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.red)
                            .frame(width: 22, height: 22)
                            .background(Color.red.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.k("views.model_manager.llmmanager_tab.account_78fbf7", fallback: "移除该账户"))
                }
                .opacity(hoveredCardId == provider.id ? 1.0 : 0.0)
            }
            .frame(height: 38)
            
            Spacer(minLength: 0)
            
            // 下方展示区：保证高度绝对单行对齐
            if isCustom, let url = provider.customBaseURL, !url.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .help(url) // 悬停展示完整链接
            } else {
                // 模型列表 - 渲染为精美的单行横向滚动胶囊，极佳的视觉减负与对齐美化
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(provider.modelIds, id: \.self) { modelId in
                            let entry = builtInModelGroups.flatMap(\.models).first { $0.id == modelId }
                            let label = entry?.label ?? modelId
                            
                            HStack(spacing: 5) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 4))
                                    .foregroundStyle(hasKey ? Color.green.opacity(0.6) : Color.secondary.opacity(0.4))
                                
                                Text(label)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(colorScheme == .dark ? 0.08 : 0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .help(modelId) // 鼠标悬停显示完整 modelId，兼顾查阅体验
                        }
                    }
                }
            }
        }
        .frame(height: 92) // 限制内部容器高度，加上 premiumCard 自带的 18 Padding * 2，刚好是 128pt 完美卡片高度
        .premiumCard(theme: cardTheme, isAvailable: true)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                if hovering {
                    hoveredCardId = provider.id
                } else if hoveredCardId == provider.id {
                    hoveredCardId = nil
                }
            }
        }
    }

    private func refreshConfiguredSecrets() {
        configuredSecretKeys = Set(GlobalSecretsStore.shared.allEntries().map(\.secretKey))
    }
}
