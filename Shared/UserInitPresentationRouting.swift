import Foundation

enum UserInitPresentationRoute: Equatable {
    case loading
    case standaloneWizard
    case detailTabs
}

func resolveUserInitPresentation(
    versionChecked: Bool,
    hasInitStep: Bool,
    hasPendingInitWizard: Bool,
    hasInstalledOpenClawHint: Bool,
    isGatewayOperationalHint: Bool,
    isAdmin: Bool,
    isMacOSUser: Bool
) -> UserInitPresentationRoute {
    let hasEntryHint = hasInstalledOpenClawHint || isGatewayOperationalHint
    if !versionChecked && !hasInitStep && !hasPendingInitWizard && !hasEntryHint && !isAdmin && isMacOSUser {
        return .loading
    }

    if !isAdmin && isMacOSUser && (hasInitStep || hasPendingInitWizard) {
        return .standaloneWizard
    }

    return .detailTabs
}

func shouldOpenUserInitWizardFromEntry(
    hasForcedOnboarding: Bool,
    hasUnfinishedWizardState: Bool,
    hasRecoverableWizardProgress: Bool,
    hasInstalledOpenClaw: Bool,
    isGatewayOperational: Bool,
    isAdmin: Bool,
    isMacOSUser: Bool
) -> Bool {
    guard !isAdmin, isMacOSUser else { return false }

    if hasForcedOnboarding || hasRecoverableWizardProgress {
        return true
    }

    // 入口规则：只要初始化状态未完成，统一进入初始化窗口，避免先开详情再被详情页二次拉起向导。
    if hasUnfinishedWizardState {
        return true
    }

    if !hasInstalledOpenClaw && !isGatewayOperational {
        return false
    }

    return false
}

func shouldEmbedOverviewGatewayConsole(
    selectedTabRawValue: String,
    initPresentationRoute: UserInitPresentationRoute,
    isAdmin: Bool,
    versionChecked: Bool,
    hasInstalledOpenClaw: Bool,
    isGatewayOperational: Bool
) -> Bool {
    guard selectedTabRawValue == "overview" else { return false }
    guard initPresentationRoute == .detailTabs else { return false }

    // 管理员账号：仅当确认未安装且网关也未运行时，才不嵌入控制台区域。
    if isAdmin && versionChecked && !hasInstalledOpenClaw && !isGatewayOperational {
        return false
    }

    return true
}

func shouldShowOverviewNativeSidebar(
    selectedTabRawValue: String,
    initPresentationRoute: UserInitPresentationRoute
) -> Bool {
    selectedTabRawValue == "overview" && initPresentationRoute == .detailTabs
}

func shouldShowDetailSidebarLabels(isCollapsed: Bool) -> Bool {
    !isCollapsed
}

func shouldRenderOverviewSidebarPanel(
    selectedTabRawValue: String,
    initPresentationRoute: UserInitPresentationRoute,
    isCollapsed: Bool
) -> Bool {
    shouldShowOverviewNativeSidebar(
        selectedTabRawValue: selectedTabRawValue,
        initPresentationRoute: initPresentationRoute
    ) && !isCollapsed
}

func shouldShowOverviewSupplementaryEntries(
    selectedTabRawValue: String,
    initPresentationRoute: UserInitPresentationRoute
) -> Bool {
    shouldShowOverviewNativeSidebar(
        selectedTabRawValue: selectedTabRawValue,
        initPresentationRoute: initPresentationRoute
    )
}
