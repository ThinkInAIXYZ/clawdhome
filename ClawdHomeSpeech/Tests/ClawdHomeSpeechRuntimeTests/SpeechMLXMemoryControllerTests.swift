import XCTest
@testable import ClawdHomeSpeechRuntime

final class SpeechMLXMemoryControllerTests: XCTestCase {
    private final class FakeBackend: SpeechMLXMemoryBackend {
        var activeMemoryBytes = 100
        var cacheMemoryBytes = 200
        var peakMemoryBytes = 300
        var events: [String] = []
        var cacheLimitBytes = 0 {
            didSet { events.append("limit:\(cacheLimitBytes)") }
        }

        func clearCache() {
            events.append("clear")
            cacheMemoryBytes = 0
        }
    }

    private enum TestError: Error {
        case failed
    }

    func testConfigureSetsLimitBeforeClearingAndReturnsSnapshot() {
        let backend = FakeBackend()
        let controller = SpeechMLXMemoryController(
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            backend: backend
        )

        let snapshot = controller.configure()

        XCTAssertEqual(backend.events, ["limit:536870912", "clear"])
        XCTAssertEqual(snapshot.activeMemoryBytes, 100)
        XCTAssertEqual(snapshot.cacheMemoryBytes, 0)
        XCTAssertEqual(snapshot.peakMemoryBytes, 300)
        XCTAssertEqual(snapshot.cacheLimitBytes, 536870912)
    }

    func testRunReclaimingReturnsValueAndPostClearSnapshot() {
        let backend = FakeBackend()
        let controller = SpeechMLXMemoryController(
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            backend: backend
        )

        let result = controller.runReclaiming { "transcript" }

        XCTAssertEqual(result.value, "transcript")
        XCTAssertEqual(result.snapshot.cacheMemoryBytes, 0)
        XCTAssertEqual(backend.events, ["clear"])
    }

    func testRunReclaimingClearsWhenOperationThrows() {
        let backend = FakeBackend()
        let controller = SpeechMLXMemoryController(
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            backend: backend
        )

        XCTAssertThrowsError(
            try controller.runReclaiming { () throws -> String in
                throw TestError.failed
            }
        )
        XCTAssertEqual(backend.events, ["clear"])
    }
}
