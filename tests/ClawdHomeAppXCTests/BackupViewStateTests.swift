// tests/ClawdHomeAppXCTests/BackupViewStateTests.swift
// 备份页状态测试：工具栏备份目标与列表筛选互不污染

import XCTest
@testable import ClawdHome

final class BackupViewStateTests: XCTestCase {
    func testPickingToolbarBackupTargetDoesNotChangeShrimpBackupFilter() {
        var state = BackupViewSelectionState(
            backupTargetUsername: nil,
            filterUsername: "intel_agent"
        )

        state.pickToolbarBackupTarget("hermes3")

        XCTAssertEqual(state.backupTargetUsername, "hermes3")
        XCTAssertEqual(state.filterUsername, "intel_agent")
    }
}
