import XCTest

final class LocalLLMDownloadPlanTests: XCTestCase {
    func testDownloadPlanUsesSwiftHuggingFaceSnapshotDestination() throws {
        let plan = try LocalModelDownloadPlan.make(
            modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            modelRootPath: "/var/lib/clawdhome/models/omlx"
        )

        XCTAssertEqual(plan.repoID, "mlx-community/Qwen2.5-7B-Instruct-4bit")
        XCTAssertEqual(plan.destinationPath, "/var/lib/clawdhome/models/omlx/Qwen2.5-7B-Instruct-4bit")
        XCTAssertEqual(plan.cachePath, "/var/lib/clawdhome/models/omlx/.hf-cache")
        XCTAssertFalse(plan.requiresPythonHuggingFaceHub)
    }
}
