// 终端控制序列回归脚本：
// 1. CPR / OSC 10 / OSC 11 查询会被 helper 侧拦截并即时响应
// 2. 这些查询不会再泄漏到可见输出
// 3. SwiftTerm 自动回包不会再被转发回 PTY，避免串到提示符

import Foundation

func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Assertion failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct TerminalControlSequenceRegression {
    static func main() {
        testInterceptsTerminalQueries()
        testHandlesSplitOSC11Query()
        testSuppressesKnownAutoResponses()
        print("terminal-control-sequence regression passed")
    }

    private static func testInterceptsTerminalQueries() {
        let chunk = Data("hello\u{1B}[6n world \u{1B}]11;?\u{07}done".utf8)
        let result = TerminalControlSequence.interceptOutputChunk(chunk)

        assert(String(decoding: result.visibleData, as: UTF8.self) == "hello world done", "query bytes should not leak into visible output")
        assert(result.carryover.isEmpty, "complete query chunk should not leave carryover")
        assert(result.responses.count == 2, "should emit CPR and OSC 11 replies")
        assert(result.responses[0] == Data("\u{1B}[1;1R".utf8), "CPR response should be immediate and stable")
        assert(result.responses[1] == Data("\u{1B}]11;rgb:0a12/0a12/0a12\u{1B}\\".utf8), "OSC 11 response should use dark background value")
    }

    private static func testHandlesSplitOSC11Query() {
        let part1 = Data("before\u{1B}]11;?".utf8)
        let part2 = Data("\u{07}after".utf8)

        let first = TerminalControlSequence.interceptOutputChunk(part1)
        assert(String(decoding: first.visibleData, as: UTF8.self) == "before", "leading text should flush before incomplete query")
        assert(!first.carryover.isEmpty, "incomplete OSC query should be buffered")
        assert(first.responses.isEmpty, "incomplete query should not answer early")

        let second = TerminalControlSequence.interceptOutputChunk(part2, carryover: first.carryover)
        assert(String(decoding: second.visibleData, as: UTF8.self) == "after", "trailing text should remain after query is stripped")
        assert(second.responses == [Data("\u{1B}]11;rgb:0a12/0a12/0a12\u{1B}\\".utf8)], "split OSC 11 query should still get one response")
        assert(second.carryover.isEmpty, "completed split query should drain carryover")
    }

    private static func testSuppressesKnownAutoResponses() {
        assert(TerminalControlSequence.shouldSuppressAutoResponse(Data("\u{1B}[1;1R".utf8)), "CPR auto-response should be suppressed on app side")
        assert(TerminalControlSequence.shouldSuppressAutoResponse(Data("\u{1B}]11;rgb:0a12/0a12/0a12\u{1B}\\".utf8)), "OSC 11 auto-response should be suppressed on app side")
        assert(!TerminalControlSequence.shouldSuppressAutoResponse(Data("ls -la\n".utf8)), "user input must keep flowing")
    }
}
