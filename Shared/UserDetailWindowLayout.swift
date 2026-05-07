import Foundation

struct ProcessTableColumnLayout {
    let pid: Double
    let name: Double
    let command: Double
    let cpu: Double
    let mem: Double
    let state: Double
    let uptime: Double
    let ports: Double
    let purpose: Double

    var totalColumnWidth: Double {
        pid + name + command + cpu + mem + state + uptime + ports + purpose
    }
}

enum UserDetailWindowLayout {
    static let mainWindowDefaultWidth: Double = 1040
    static let hermesDetailWindowPreferredWidth: Double = 1180
    static let detailWindowDefaultHeight: Double = 792
    static let detailWindowMinimumWidth: Double = 960
    static let detailWindowMinimumHeight: Double = 672
    static let expandedSidebarWidth: Double = 180
    static let overviewSidebarWidth: Double = 296
    static let overviewSidebarPadding: Double = 18
    static let overviewSidebarSectionSpacing: Double = 16
    static let overviewStatusCardIconSize: Double = 52
    static let overviewStatusCardPadding: Double = 16
    static let overviewFloatingToolbarButtonSize: Double = 28
    static let overviewFloatingHeaderTopPadding: Double = 6
    static let overviewFloatingHeaderInset: Double = 0
    static let overviewActionButtonHeight: Double = 36
    static let overviewActionButtonCornerRadius: Double = 12
    static let overviewCompactActionSpacing: Double = 12
    static let overviewSupplementaryCardPadding: Double = 16
    static let overviewSupplementaryCardCornerRadius: Double = 16
    static let overviewMetricRowVerticalPadding: Double = 14
    static let overviewPrimaryButtonHeight: Double = 46
    static let overviewPrimaryButtonCornerRadius: Double = 14
    static let tableColumnHorizontalPadding: Double = 8
    static let tableContainerHorizontalPadding: Double = 16
    static let tableColumnCount: Double = 9

    static let defaultProcessColumns = ProcessTableColumnLayout(
        pid: 52,
        name: 160,
        command: 160,
        cpu: 48,
        mem: 54,
        state: 56,
        uptime: 52,
        ports: 88,
        purpose: 96
    )
}

func resolvedUserDetailWindowWidth(
    mainWindowWidth: Double,
    visibleWidth: Double
) -> Double {
    let clampedVisibleWidth = max(UserDetailWindowLayout.detailWindowMinimumWidth, visibleWidth)
    return max(
        UserDetailWindowLayout.detailWindowMinimumWidth,
        min(mainWindowWidth, clampedVisibleWidth)
    )
}

func defaultProcessTableRequiredWidth(
    columns: ProcessTableColumnLayout = UserDetailWindowLayout.defaultProcessColumns
) -> Double {
    columns.totalColumnWidth
        + UserDetailWindowLayout.tableColumnHorizontalPadding * UserDetailWindowLayout.tableColumnCount
        + UserDetailWindowLayout.tableContainerHorizontalPadding
}

func userDetailProcessContentBudget(
    detailWindowWidth: Double = UserDetailWindowLayout.mainWindowDefaultWidth,
    sidebarWidth: Double = UserDetailWindowLayout.expandedSidebarWidth
) -> Double {
    detailWindowWidth - sidebarWidth
}

func overviewSidebarWidth() -> Double {
    UserDetailWindowLayout.overviewSidebarWidth
}

func overviewSidebarPadding() -> Double {
    UserDetailWindowLayout.overviewSidebarPadding
}

func overviewSidebarFloatingHeaderInset() -> Double {
    UserDetailWindowLayout.overviewFloatingHeaderInset
}

func overviewActionButtonHeight() -> Double {
    UserDetailWindowLayout.overviewActionButtonHeight
}

func overviewPrimaryButtonHeight() -> Double {
    UserDetailWindowLayout.overviewPrimaryButtonHeight
}
