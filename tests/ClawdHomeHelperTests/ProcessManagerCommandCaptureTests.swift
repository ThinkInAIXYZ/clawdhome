import XCTest

final class ProcessManagerCommandCaptureTests: XCTestCase {
    func testCaptureCommandOutputHandlesLargeStdoutWithoutDeadlock() throws {
        let command = #"for i in $(seq 1 2000); do printf 'line-%04d %080d\n' "$i" "$i"; done"#

        let result = try XCTUnwrap(
            CommandOutputCapture.run(
                executablePath: "/bin/sh",
                arguments: ["-c", command]
            )
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertGreaterThan(result.stdout.count, 128 * 1024)
        XCTAssertTrue(String(data: result.stdout, encoding: .utf8)?.contains("line-2000") == true)
    }
}
