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
    isAdmin: Bool,
    isMacOSUser: Bool
) -> UserInitPresentationRoute {
    if !versionChecked && !hasInitStep {
        return .loading
    }

    if !isAdmin && isMacOSUser && (hasInitStep || hasPendingInitWizard) {
        return .standaloneWizard
    }

    return .detailTabs
}
