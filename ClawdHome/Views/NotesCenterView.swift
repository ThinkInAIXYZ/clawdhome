import AppKit
import Observation
import SwiftUI

private enum NotesCenterTab: String, CaseIterable, Identifiable {
    case overview
    case configuration
    case shrimps
    case maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .configuration: return "Configuration"
        case .shrimps: return "Shrimps"
        case .maintenance: return "Maintenance"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .configuration: return "slider.horizontal.3"
        case .shrimps: return "person.3"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

private enum NotesStatusTone {
    case neutral
    case success
    case warning
    case critical

    var tint: Color {
        switch self {
        case .neutral: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var background: Color {
        switch self {
        case .neutral: return Color.primary.opacity(0.05)
        case .success: return .green.opacity(0.12)
        case .warning: return .orange.opacity(0.12)
        case .critical: return .red.opacity(0.12)
        }
    }

    var border: Color {
        tint.opacity(0.2)
    }
}

private struct NotesAlertItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let tone: NotesStatusTone
}

struct NotesCenterView: View {
    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self) private var pool
    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(GlobalModelStore.self) private var modelStore

    @State private var store = LLMWikiNotesCenterStore()
    @State private var selectedTab: NotesCenterTab = .overview
    @State private var shrimpSearchText = ""
    @State private var issueOnlyMode = false
    @State private var expandedShrimps: Set<String> = []

    private var summaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 12, alignment: .topLeading)]
    }

    private var detailColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 260, maximum: 520), spacing: 16, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                tabStrip

                tabContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Wiki Support")
        .task {
            await refreshStatus()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ClawdHome Wiki Support")
                        .font(.system(size: 30, weight: .semibold))
                    Text("A calmer workspace for runtime health, project binding, local store settings, and per-shrimp note mappings.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let statusMessage = store.statusMessage, !statusMessage.isEmpty {
                        NotesMessageBanner(text: statusMessage, tone: .success)
                    }
                    if let errorMessage = store.errorMessage, !errorMessage.isEmpty {
                        NotesMessageBanner(text: errorMessage, tone: .critical)
                    }
                }

                Spacer(minLength: 24)

                VStack(alignment: .trailing, spacing: 12) {
                    NotesStatusPill(title: overallStatusTitle, tone: overallStatusTone)

                    if store.isLoading {
                        ProgressView("Refreshing…")
                            .controlSize(.small)
                    }

                    ViewThatFits {
                        HStack(spacing: 10) {
                            launchButton
                            refreshButton
                        }
                        VStack(alignment: .trailing, spacing: 10) {
                            launchButton
                            refreshButton
                        }
                    }
                }
            }

            Divider()

            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                NotesStatTile(
                    title: "Runtime",
                    value: runtimeSummaryValue,
                    detail: runtimeSummaryDetail,
                    tone: runtimeStatusTone
                )
                NotesStatTile(
                    title: "Shared Project",
                    value: projectSummaryValue,
                    detail: projectSummaryDetail,
                    tone: projectStatusTone
                )
                NotesStatTile(
                    title: "Local Store",
                    value: storeSummaryValue,
                    detail: storeSummaryDetail,
                    tone: storeStatusTone
                )
                NotesStatTile(
                    title: "Shrimp Coverage",
                    value: shrimpSummaryValue,
                    detail: shrimpSummaryDetail,
                    tone: shrimpStatusTone
                )
            }
        }
        .padding(24)
        .background(panelBackground)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            overviewTab
        case .configuration:
            NotesConfigurationPanel(
                store: store,
                users: pool.users,
                modelStore: modelStore,
                helperClient: helperClient,
                gatewayHub: gatewayHub
            )
        case .shrimps:
            shrimpsTab
        case .maintenance:
            maintenanceTab
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 10) {
            ForEach(NotesCenterTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    NotesTabChip(
                        title: tab.title,
                        icon: tab.icon,
                        badge: badgeText(for: tab),
                        isSelected: selectedTab == tab
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            NotesPanel(
                title: "Current Status",
                subtitle: "The main signals to check before editing note settings or repairing a shrimp workspace."
            ) {
                LazyVGrid(columns: detailColumns, alignment: .leading, spacing: 16) {
                    NotesKeyValueBlock(label: "Installed", value: yesNo(store.appInstalled))
                    NotesKeyValueBlock(label: "Running", value: yesNo(store.appRunning))
                    NotesKeyValueBlock(label: "HTTP Over UDS Ready", value: readyValue)
                    NotesKeyValueBlock(label: "Shared Project Complete", value: yesNo(store.globalAudit?.projectStructureComplete == true))
                    NotesKeyValueBlock(label: "Store File", value: storeFileValue)
                    NotesKeyValueBlock(label: "Last Project", value: store.storeSnapshot.lastProject ?? "Not Set")
                    NotesKeyValueBlock(label: "Ready Shrimps", value: shrimpSummaryValue)
                    NotesKeyValueBlock(label: "Needs Attention", value: "\(issueUserCount)")
                }
            }

            NotesPanel(
                title: "Attention Queue",
                subtitle: "Use this list to see what is actually broken instead of scanning every path manually."
            ) {
                if overviewAlerts.isEmpty {
                    ContentUnavailableView(
                        "Everything Looks Healthy",
                        systemImage: "checkmark.seal",
                        description: Text("Runtime, shared project, local store, and shrimp note mappings are all in a usable state.")
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(overviewAlerts) { alert in
                            NotesAlertRow(alert: alert)
                        }
                    }
                }
            }
        }
    }

    private var shrimpsTab: some View {
        NotesPanel(
            title: "Per-Shrimp Notes Mapping",
            subtitle: "Each shrimp should have a private notes directory, a shared project symlink, and a usable workspace skill."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search shrimp", text: $shrimpSearchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )

                    Toggle("Issues Only", isOn: $issueOnlyMode)
                        .toggleStyle(.switch)

                    Spacer()

                    Text("\(filteredUserStates.count) shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if filteredUserStates.isEmpty {
                    ContentUnavailableView(
                        "No Matching Shrimps",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Adjust the search query or turn off issue-only mode.")
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredUserStates) { state in
                            shrimpCard(state)
                        }
                    }
                }
            }
        }
    }

    private var maintenanceTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            NotesPanel(
                title: "Quick Actions",
                subtitle: "Repair shared runtime pieces or relaunch LLM Wiki without leaving the Notes Center."
            ) {
                ViewThatFits {
                    HStack(spacing: 10) {
                        launchButton
                        repairProjectButton
                        refreshButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        launchButton
                        repairProjectButton
                        refreshButton
                    }
                }
            }

            NotesPanel(
                title: "Runtime Audit",
                subtitle: "Socket readiness, permissions, and health endpoints for the shared LLM Wiki runtime."
            ) {
                LazyVGrid(columns: detailColumns, alignment: .leading, spacing: 16) {
                    NotesKeyValueBlock(label: "Installed", value: yesNo(store.appInstalled))
                    NotesKeyValueBlock(label: "Running", value: yesNo(store.appRunning))
                    NotesKeyValueBlock(label: "Shared Project Complete", value: yesNo(store.globalAudit?.projectStructureComplete == true))
                    NotesKeyValueBlock(label: "Main Socket", value: yesNo(store.globalAudit?.socketExists == true))
                    NotesKeyValueBlock(label: "Heartbeat Socket", value: yesNo(store.globalAudit?.heartbeatExists == true))
                    NotesKeyValueBlock(label: "Metadata File", value: yesNo(store.globalAudit?.metadataExists == true))
                    NotesKeyValueBlock(label: "HTTP Over UDS", value: readyValue)
                    NotesKeyValueBlock(label: "Runtime Owner:Group", value: runtimeOwnerGroup)
                    NotesKeyValueBlock(label: "Runtime Mode", value: store.globalAudit?.runtimeMode ?? "Unknown")
                    NotesKeyValueBlock(label: "Metadata Security", value: metadataSecuritySummary)
                }
            }

            NotesPanel(
                title: "Paths & Bindings",
                subtitle: "These paths should stay stable. They connect the desktop app, shared project, runtime sockets, and each shrimp workspace."
            ) {
                LazyVGrid(columns: detailColumns, alignment: .leading, spacing: 16) {
                    NotesKeyValueBlock(label: "Shared Project Path", value: LLMWikiPaths.projectRoot)
                    NotesKeyValueBlock(label: "Shared Runtime Path", value: LLMWikiPaths.runtimeRoot)
                    NotesKeyValueBlock(label: "Main Socket Path", value: LLMWikiPaths.socketPath)
                    NotesKeyValueBlock(label: "Heartbeat Path", value: LLMWikiPaths.heartbeatSocketPath)
                    NotesKeyValueBlock(label: "Metadata Path", value: LLMWikiPaths.metadataPath)
                    NotesKeyValueBlock(label: "Store File Path", value: store.storeSnapshot.path)
                }
            }
        }
    }

    private var launchButton: some View {
        Button(store.appRunning ? "Restart LLM Wiki" : "Launch LLM Wiki") {
            launchOrRestart()
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isLoading)
    }

    private var repairProjectButton: some View {
        Button("Repair Shared Project") {
            repairGlobal()
        }
        .buttonStyle(.bordered)
        .disabled(store.isLoading)
    }

    private var refreshButton: some View {
        Button("Refresh Status") {
            Task { await refreshStatus() }
        }
        .buttonStyle(.bordered)
        .disabled(store.isLoading)
    }

    private var overviewAlerts: [NotesAlertItem] {
        var items: [NotesAlertItem] = []

        if !store.appInstalled {
            items.append(
                NotesAlertItem(
                    id: "runtime-install",
                    icon: "shippingbox",
                    title: "Embedded Wiki runtime is missing",
                    detail: "Rebuild or repair the bundled runtime before checking note mappings.",
                    tone: .critical
                )
            )
        } else if !store.appRunning {
            items.append(
                NotesAlertItem(
                    id: "runtime-running",
                    icon: "bolt.horizontal.circle",
                    title: "LLM Wiki is not running",
                    detail: "Launch or restart the managed runtime to restore socket and health checks.",
                    tone: .warning
                )
            )
        }

        if store.globalAudit?.projectStructureComplete != true {
            items.append(
                NotesAlertItem(
                    id: "project-structure",
                    icon: "folder.badge.questionmark",
                    title: "Shared project structure is incomplete",
                    detail: "Repair the shared project so the shared wiki folders, sockets, and metadata land in the expected locations.",
                    tone: .warning
                )
            )
        }

        if !store.storeSnapshot.exists {
            items.append(
                NotesAlertItem(
                    id: "store-missing",
                    icon: "externaldrive.badge.exclamationmark",
                    title: "Local store file is missing",
                    detail: "Save configuration or repair project binding to recreate the LLM Wiki app-state file.",
                    tone: .warning
                )
            )
        }

        for state in issueUsers {
            items.append(
                NotesAlertItem(
                    id: "user-\(state.audit.username)",
                    icon: "person.crop.circle.badge.exclamationmark",
                    title: "@\(state.audit.username) needs repair",
                    detail: missingComponents(for: state).joined(separator: ", "),
                    tone: .warning
                )
            )
        }

        return items
    }

    private var issueUsers: [LLMWikiUserState] {
        store.userStates.filter { !isUserReady($0) }
    }

    private var issueUserCount: Int {
        issueUsers.count
    }

    private var readyUserCount: Int {
        store.userStates.filter(isUserReady).count
    }

    private var filteredUserStates: [LLMWikiUserState] {
        let query = shrimpSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.userStates.filter { state in
            let matchesIssue = !issueOnlyMode || !isUserReady(state)
            let matchesQuery = query.isEmpty || state.audit.username.lowercased().contains(query)
            return matchesIssue && matchesQuery
        }
    }

    private var overallStatusTone: NotesStatusTone {
        if runtimeStatusTone == .critical {
            return .critical
        }
        if runtimeStatusTone == .warning || projectStatusTone == .warning || storeStatusTone == .warning || issueUserCount > 0 {
            return .warning
        }
        return .success
    }

    private var overallStatusTitle: String {
        switch overallStatusTone {
        case .success: return "Operational"
        case .warning: return "Needs Attention"
        case .critical: return "Blocked"
        case .neutral: return "Checking"
        }
    }

    private var runtimeStatusTone: NotesStatusTone {
        guard store.appInstalled else { return .critical }
        guard store.appRunning else { return .warning }
        return store.healthStatus?.ready == true ? .success : .warning
    }

    private var projectStatusTone: NotesStatusTone {
        store.globalAudit?.projectStructureComplete == true ? .success : .warning
    }

    private var storeStatusTone: NotesStatusTone {
        store.storeSnapshot.exists ? .success : .warning
    }

    private var shrimpStatusTone: NotesStatusTone {
        store.userStates.isEmpty ? .neutral : (issueUserCount == 0 ? .success : .warning)
    }

    private var runtimeSummaryValue: String {
        guard store.appInstalled else { return "Not Installed" }
        guard store.appRunning else { return "Stopped" }
        return store.healthStatus?.ready == true ? "Ready" : "Degraded"
    }

    private var runtimeSummaryDetail: String {
        guard store.appInstalled else { return "Embedded runtime is missing from the app bundle." }
        guard store.appRunning else { return "Sockets and health checks are offline." }
        return readyValue
    }

    private var projectSummaryValue: String {
        store.globalAudit?.projectStructureComplete == true ? "Healthy" : "Repair Needed"
    }

    private var projectSummaryDetail: String {
        store.globalAudit?.projectStructureComplete == true
            ? "Shared project folders and runtime hooks are in place."
            : "Project folders, sockets, or metadata are incomplete."
    }

    private var storeSummaryValue: String {
        store.storeSnapshot.exists ? "Present" : "Missing"
    }

    private var storeSummaryDetail: String {
        if let lastProject = store.storeSnapshot.lastProject, !lastProject.isEmpty {
            return lastProject
        }
        return store.storeSnapshot.exists ? "No project pinned yet." : "App-state file has not been created."
    }

    private var shrimpSummaryValue: String {
        guard !store.userStates.isEmpty else { return "0 Loaded" }
        return "\(readyUserCount) / \(store.userStates.count)"
    }

    private var shrimpSummaryDetail: String {
        guard !store.userStates.isEmpty else { return "No shrimps loaded from the current pool." }
        return issueUserCount == 0 ? "All shrimp note mappings look healthy." : "\(issueUserCount) shrimp mappings need attention."
    }

    private var storeFileValue: String {
        store.storeSnapshot.exists ? store.storeSnapshot.path : "\(store.storeSnapshot.path) (Missing)"
    }

    private var runtimeOwnerGroup: String {
        [store.globalAudit?.runtimeOwner, store.globalAudit?.runtimeGroup]
            .compactMap { $0 }
            .joined(separator: ":")
            .nilIfEmpty ?? "Unknown"
    }

    private var metadataSecuritySummary: String {
        let pieces = [store.globalAudit?.metadataSecurityGroup, store.globalAudit?.metadataSecurityMode]
            .compactMap { $0 }
        return pieces.isEmpty ? "Unknown" : pieces.joined(separator: " / ")
    }

    private var readyValue: String {
        guard let healthStatus = store.healthStatus else { return "Unavailable" }
        if healthStatus.ready { return "Ready" }
        return healthStatus.reason ?? healthStatus.status ?? "Degraded"
    }

    private func badgeText(for tab: NotesCenterTab) -> String? {
        switch tab {
        case .shrimps:
            return issueUserCount > 0 ? "\(issueUserCount)" : nil
        case .maintenance:
            let maintenanceIssues = (store.appInstalled ? 0 : 1)
                + (store.appRunning ? 0 : 1)
                + ((store.globalAudit?.projectStructureComplete == true) ? 0 : 1)
                + (store.storeSnapshot.exists ? 0 : 1)
            return maintenanceIssues > 0 ? "\(maintenanceIssues)" : nil
        default:
            return nil
        }
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private func isUserReady(_ state: LLMWikiUserState) -> Bool {
        let auditReady = state.audit.notesExists
            && state.audit.projectSymlinkValid
            && state.audit.workspaceSkillExists
        let gatewayReady = !(state.skillState?.disabled ?? false)
        return auditReady && gatewayReady
    }

    private func missingComponents(for state: LLMWikiUserState) -> [String] {
        var items: [String] = []
        if !state.audit.notesExists {
            items.append("missing notes directory")
        }
        if !state.audit.projectSymlinkValid {
            items.append("broken or missing shared-project mapping")
        }
        if !state.audit.workspaceSkillExists {
            items.append("missing workspace skill files")
        }
        if state.skillState?.disabled == true {
            items.append("gateway skill is disabled")
        }
        return items.isEmpty ? ["review workspace state"] : items
    }

    private func shrimpTone(for state: LLMWikiUserState) -> NotesStatusTone {
        isUserReady(state) ? .success : .warning
    }

    private func shrimpStatusTitle(for state: LLMWikiUserState) -> String {
        isUserReady(state) ? "Healthy" : "Needs Repair"
    }

    private func gatewayStateText(for state: LLMWikiUserState) -> String {
        if let skillState = state.skillState {
            if skillState.disabled { return "Disabled" }
            return skillState.source ?? "Connected"
        }
        return state.audit.workspaceSkillExists ? "Workspace Files Present" : "Not Installed"
    }

    private func shrimpCard(_ state: LLMWikiUserState) -> some View {
        DisclosureGroup(isExpanded: bindingForExpandedShrimp(state.audit.username)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("Repair User") {
                        repairUser(state.audit.username)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isLoading)

                    Spacer()

                    Text("Expand this section when you need paths, permissions, and skill source details.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: detailColumns, alignment: .leading, spacing: 16) {
                    NotesKeyValueBlock(label: "Notes Directory", value: state.audit.notesPath)
                    NotesKeyValueBlock(label: "Stable Entry", value: state.audit.notesEntryPath)
                    NotesKeyValueBlock(label: "Notes Owner:Group", value: [state.audit.notesOwner, state.audit.notesGroup].compactMap { $0 }.joined(separator: ":").nilIfEmpty ?? "Unknown")
                    NotesKeyValueBlock(label: "Notes Mode", value: state.audit.notesMode ?? "Unknown")
                    NotesKeyValueBlock(label: "Project Symlink", value: state.audit.projectSymlinkPath)
                    NotesKeyValueBlock(label: "Workspace Skill Path", value: state.audit.workspaceSkillPath)
                    NotesKeyValueBlock(label: "Workspace Skill Files", value: yesNo(state.audit.workspaceSkillExists))
                    NotesKeyValueBlock(label: "Gateway Skill State", value: gatewayStateText(for: state))
                }
            }
            .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(shrimpTone(for: state).tint)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("@\(state.audit.username)")
                            .font(.headline)
                        Text(missingComponents(for: state).joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    NotesStatusPill(title: shrimpStatusTitle(for: state), tone: shrimpTone(for: state))
                }

                HStack(spacing: 8) {
                    NotesMiniBadge(title: "Directory", ok: state.audit.notesExists)
                    NotesMiniBadge(title: "Symlink", ok: state.audit.projectSymlinkValid)
                    NotesMiniBadge(title: "Workspace Skill", ok: state.audit.workspaceSkillExists)
                    NotesMiniBadge(title: "Gateway Skill", ok: !(state.skillState?.disabled ?? false))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func bindingForExpandedShrimp(_ username: String) -> Binding<Bool> {
        Binding(
            get: { expandedShrimps.contains(username) },
            set: { expanded in
                if expanded {
                    expandedShrimps.insert(username)
                } else {
                    expandedShrimps.remove(username)
                }
            }
        )
    }

    private func refreshStatus() async {
        await store.refresh(users: pool.users, helperClient: helperClient, gatewayHub: gatewayHub)
    }

    private func launchOrRestart() {
        Task {
            await store.launchOrRestart(helperClient: helperClient, users: pool.users, gatewayHub: gatewayHub)
        }
    }

    private func repairGlobal() {
        Task {
            await store.repairGlobal(helperClient: helperClient, users: pool.users, gatewayHub: gatewayHub)
        }
    }

    private func repairUser(_ username: String) {
        Task {
            await store.repairUser(username: username, helperClient: helperClient, users: pool.users, gatewayHub: gatewayHub)
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

private struct NotesConfigurationPanel: View {
    @Bindable var store: LLMWikiNotesCenterStore

    let users: [ManagedUser]
    let modelStore: GlobalModelStore
    let helperClient: HelperClient
    let gatewayHub: GatewayHub

    @State private var isRestoringSelection = false
    @State private var showGlobalRefreshPrompt = false
    @State private var pendingGlobalRevision = 0

    var body: some View {
        let globalOptions = store.globalLLMConfigOptions(modelStore: modelStore)
        let selectedGlobalOption = globalOptions.first(where: { $0.id == store.selectedGlobalLLMOptionID }) ?? globalOptions.first

        VStack(alignment: .leading, spacing: 16) {
            NotesPanel(
                title: "Store & Project Binding",
                subtitle: "ClawdHome pins the shared LLM Wiki project in the desktop app-state file so notes resolve against the shared workspace."
            ) {
                LazyVGrid(columns: detailColumns, alignment: .leading, spacing: 16) {
                    NotesKeyValueBlock(label: "Store File", value: store.storeSnapshot.exists ? store.storeSnapshot.path : "\(store.storeSnapshot.path) (Missing)")
                    NotesKeyValueBlock(label: "Last Project", value: store.storeSnapshot.lastProject ?? "Not Set")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Projects")
                        .font(.subheadline.weight(.semibold))
                    if store.storeSnapshot.recentProjects.isEmpty {
                        Text("No recent projects recorded.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.storeSnapshot.recentProjects, id: \.self) { project in
                            Text(project)
                                .font(.system(.subheadline, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            NotesPanel(
                title: "LLM & Embedding Settings",
                subtitle: "Keep the note index configuration close to the shared project binding so provider changes remain easy to audit."
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("LLM Config Source")
                            .font(.headline)

                        Picker("Config Source", selection: $store.llmConfigSource) {
                            Text("Global Model Pool").tag(LLMWikiLLMConfigSource.global)
                            Text("Manual").tag(LLMWikiLLMConfigSource.manual)
                        }
                        .pickerStyle(.segmented)
                    }

                    if store.llmConfigSource == .global {
                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Assign From Global Model Pool")
                                .font(.headline)

                            if globalOptions.isEmpty {
                                Text("No compatible global model configs found. Add at least one model account in Global Model Config first.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                LabeledContent("Global Model") {
                                    Picker("Global Model", selection: $store.selectedGlobalLLMOptionID) {
                                        ForEach(globalOptions) { option in
                                            Text(option.title).tag(option.id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: 420, alignment: .trailing)
                                }

                                if let selectedGlobalOption {
                                    LazyVGrid(columns: detailColumns, alignment: .leading, spacing: 16) {
                                        NotesKeyValueBlock(label: "Selected Alias", value: selectedGlobalOption.title)
                                        NotesKeyValueBlock(label: "Provider", value: selectedGlobalOption.config.provider)
                                        NotesKeyValueBlock(label: "Model", value: selectedGlobalOption.config.model)
                                        NotesKeyValueBlock(
                                            label: "Endpoint",
                                            value: selectedGlobalOption.config.customEndpoint.nilIfEmpty
                                                ?? selectedGlobalOption.config.ollamaUrl
                                        )
                                        NotesKeyValueBlock(
                                            label: "API Key",
                                            value: selectedGlobalOption.config.apiKey.isEmpty ? "Missing" : "Configured"
                                        )
                                        NotesKeyValueBlock(
                                            label: "Max Context Size",
                                            value: "\(selectedGlobalOption.config.maxContextSize)"
                                        )
                                    }
                                }

                                Text("Saving resolves the latest provider, model, endpoint, and key from the selected global model config, then writes the concrete values into LLM Wiki store.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            Text("LLM Config")
                                .font(.headline)

                            configTextField("Provider", prompt: "openai / anthropic / custom / ollama", text: $store.editableLLMConfig.provider)
                            configTextField("Model", prompt: "model id", text: $store.editableLLMConfig.model)
                            configSecureField("API Key", prompt: "provider key", text: $store.editableLLMConfig.apiKey)
                            configTextField("Custom Endpoint", prompt: "https://...", text: $store.editableLLMConfig.customEndpoint)
                            configTextField("Ollama URL", prompt: "http://localhost:11434", text: $store.editableLLMConfig.ollamaUrl)
                            Text("Manual mode writes exactly what you enter. Ollama URL falls back to the default local endpoint if left empty.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            LabeledContent("Max Context Size") {
                                Stepper(value: $store.editableLLMConfig.maxContextSize, in: 4096...1_000_000, step: 1024) {
                                    Text("\(store.editableLLMConfig.maxContextSize)")
                                        .font(.system(.body, design: .monospaced))
                                }
                                .frame(maxWidth: 320, alignment: .trailing)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Embedding Config")
                            .font(.headline)

                        Toggle("Enable Embedding", isOn: $store.editableEmbeddingConfig.enabled)
                        configTextField("Endpoint", prompt: "https://...", text: $store.editableEmbeddingConfig.endpoint)
                        configSecureField("API Key", prompt: "embedding key", text: $store.editableEmbeddingConfig.apiKey)
                        configTextField("Model", prompt: "embedding model", text: $store.editableEmbeddingConfig.model)
                    }

                    Divider()

                    ViewThatFits {
                        HStack(spacing: 10) {
                            Button("Save Config") {
                                Task {
                                    await store.saveConfigs(users: users, helperClient: helperClient, gatewayHub: gatewayHub, modelStore: modelStore)
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Repair Project Binding") {
                                Task {
                                    await store.bindProject(users: users, helperClient: helperClient, gatewayHub: gatewayHub)
                                }
                            }
                            .buttonStyle(.bordered)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Button("Save Config") {
                                Task {
                                    await store.saveConfigs(users: users, helperClient: helperClient, gatewayHub: gatewayHub, modelStore: modelStore)
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Repair Project Binding") {
                                Task {
                                    await store.bindProject(users: users, helperClient: helperClient, gatewayHub: gatewayHub)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .onAppear {
            isRestoringSelection = true
            store.loadPersistedLLMConfigSelection(modelStore: modelStore)
            DispatchQueue.main.async {
                isRestoringSelection = false
            }
        }
        .onChange(of: store.llmConfigSource) { _, newSource in
            guard !isRestoringSelection else { return }
            store.syncSelectedGlobalLLMOption(modelStore: modelStore)
            if newSource == .global {
                store.applySelectedGlobalLLMConfig(modelStore: modelStore)
            }
            store.persistLLMConfigSelection()
        }
        .onChange(of: store.selectedGlobalLLMOptionID) { _, _ in
            guard !isRestoringSelection else { return }
            store.syncSelectedGlobalLLMOption(modelStore: modelStore)
            guard store.llmConfigSource == .global, !store.selectedGlobalLLMOptionID.isEmpty else {
                store.persistLLMConfigSelection()
                return
            }
            store.applySelectedGlobalLLMConfig(modelStore: modelStore)
            store.persistLLMConfigSelection()
        }
        .onChange(of: modelStore.revision) { _, newRevision in
            store.syncSelectedGlobalLLMOption(modelStore: modelStore)
            if store.llmConfigSource == .global && newRevision != store.observedGlobalRevision {
                pendingGlobalRevision = newRevision
                showGlobalRefreshPrompt = true
            }
        }
        .alert("Global Model Pool Updated", isPresented: $showGlobalRefreshPrompt) {
            Button("Refresh From Global") {
                store.applySelectedGlobalLLMConfig(modelStore: modelStore, updateObservedRevision: true)
                store.persistLLMConfigSelection()
            }
            Button("Keep Current", role: .cancel) {
                store.observedGlobalRevision = pendingGlobalRevision
                store.persistLLMConfigSelection()
            }
        } message: {
            Text("The selected global model config changed. Refresh Notes Center to use the latest global provider, model, endpoint, and key, or keep the current concrete values.")
        }
    }

    private var detailColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 260, maximum: 520), spacing: 16, alignment: .topLeading)]
    }

    @ViewBuilder
    private func configTextField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
        }
    }

    @ViewBuilder
    private func configSecureField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            SecureField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
        }
    }
}

private struct NotesPanel<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct NotesTabChip: View {
    let title: String
    let icon: String
    let badge: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
                .font(.subheadline.weight(.medium))
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.08))
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
    }
}

private struct NotesStatTile: View {
    let title: String
    let value: String
    let detail: String
    let tone: NotesStatusTone

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(tone.tint)
                    .frame(width: 8, height: 8)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tone.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tone.border, lineWidth: 1)
        )
    }
}

private struct NotesKeyValueBlock: View {
    let label: String
    let value: String

    private var usesMonospace: Bool {
        value.contains("/") || value.contains(":") || value.contains(".sock")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value.isEmpty ? "-" : value)
                .font(usesMonospace ? .system(.subheadline, design: .monospaced) : .subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NotesStatusPill: View {
    let title: String
    let tone: NotesStatusTone

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(tone.background)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tone.border, lineWidth: 1)
            )
            .foregroundStyle(tone.tint)
    }
}

private struct NotesMiniBadge: View {
    let title: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill((ok ? Color.green : Color.orange).opacity(0.1))
        )
        .foregroundStyle(ok ? Color.green : Color.orange)
    }
}

private struct NotesMessageBanner: View {
    let text: String
    let tone: NotesStatusTone

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tone == .critical ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tone.tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tone.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tone.border, lineWidth: 1)
        )
    }
}

private struct NotesAlertRow: View {
    let alert: NotesAlertItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.icon)
                .foregroundStyle(alert.tone.tint)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(alert.title)
                    .font(.subheadline.weight(.semibold))
                Text(alert.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            NotesStatusPill(title: alert.tone == .critical ? "Critical" : "Review", tone: alert.tone)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(alert.tone.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(alert.tone.border, lineWidth: 1)
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
