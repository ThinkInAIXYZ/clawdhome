// Shared/TerminalControlSequence.swift
// 终端控制序列解析与过滤（App / Helper 共用）

import Foundation

struct TerminalControlSequenceInterceptResult {
    let visibleData: Data
    let responses: [Data]
    let carryover: Data
}

enum TerminalControlSequence {
    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07

    // 使用稳定的深色背景/浅色前景，核心目标是让提示程序知道查询可用，
    // 避免异步回包串到 prompt，而不是精确复刻当前 UI 主题。
    private static let defaultForeground = "rgb:ffff/ffff/ffff"
    private static let defaultBackground = "rgb:0a12/0a12/0a12"

    static func interceptOutputChunk(
        _ chunk: Data,
        carryover: Data = Data(),
        foregroundRGB: String = defaultForeground,
        backgroundRGB: String = defaultBackground
    ) -> TerminalControlSequenceInterceptResult {
        let bytes = [UInt8](carryover + chunk)
        var visible = Data()
        var responses: [Data] = []
        var index = 0

        while index < bytes.count {
            if let matched = matchCPRQuery(in: bytes, at: index) {
                responses.append(Data("\u{1B}[1;1R".utf8))
                index += matched
                continue
            }

            if let oscMatch = matchOSCQuery(in: bytes, at: index) {
                switch oscMatch.kind {
                case .foreground:
                    responses.append(makeOSCResponse(code: "10", value: foregroundRGB))
                case .background:
                    responses.append(makeOSCResponse(code: "11", value: backgroundRGB))
                }
                index += oscMatch.length
                continue
            }

            if isKnownQueryPrefix(bytes[index...]) {
                return TerminalControlSequenceInterceptResult(
                    visibleData: visible,
                    responses: responses,
                    carryover: Data(bytes[index...])
                )
            }

            visible.append(bytes[index])
            index += 1
        }

        return TerminalControlSequenceInterceptResult(
            visibleData: visible,
            responses: responses,
            carryover: Data()
        )
    }

    static func shouldSuppressAutoResponse(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        if isCPRResponse(bytes) {
            return true
        }
        if let osc = parseOSCResponse(bytes), osc == "10" || osc == "11" {
            return true
        }
        return false
    }

    private enum OSCQueryKind {
        case foreground
        case background
    }

    private struct OSCQueryMatch {
        let kind: OSCQueryKind
        let length: Int
    }

    private static func matchCPRQuery(in bytes: [UInt8], at index: Int) -> Int? {
        let pattern: [UInt8] = [esc, 0x5B, 0x36, 0x6E] // ESC [ 6 n
        guard hasPrefix(bytes, at: index, pattern) else { return nil }
        return pattern.count
    }

    private static func matchOSCQuery(in bytes: [UInt8], at index: Int) -> OSCQueryMatch? {
        guard index + 5 < bytes.count else { return nil }
        guard bytes[index] == esc, bytes[index + 1] == 0x5D else { return nil } // ESC ]

        let code: String
        let kind: OSCQueryKind
        if bytes[index + 2] == 0x31, bytes[index + 3] == 0x30, bytes[index + 4] == 0x3B, bytes[index + 5] == 0x3F {
            code = "10"
            kind = .foreground
        } else if bytes[index + 2] == 0x31, bytes[index + 3] == 0x31, bytes[index + 4] == 0x3B, bytes[index + 5] == 0x3F {
            code = "11"
            kind = .background
        } else {
            return nil
        }
        _ = code

        let terminatorIndex = index + 6
        if terminatorIndex >= bytes.count {
            return nil
        }
        if bytes[terminatorIndex] == bel {
            return OSCQueryMatch(kind: kind, length: 7)
        }
        if bytes[terminatorIndex] == esc, terminatorIndex + 1 < bytes.count, bytes[terminatorIndex + 1] == 0x5C {
            return OSCQueryMatch(kind: kind, length: 8)
        }
        return nil
    }

    private static func isKnownQueryPrefix(_ slice: ArraySlice<UInt8>) -> Bool {
        let candidates: [[UInt8]] = [
            [esc, 0x5B, 0x36, 0x6E],       // ESC [ 6 n
            [esc, 0x5D, 0x31, 0x30, 0x3B, 0x3F], // ESC ] 10 ; ?
            [esc, 0x5D, 0x31, 0x31, 0x3B, 0x3F], // ESC ] 11 ; ?
        ]
        let prefix = Array(slice)
        return candidates.contains { candidate in
            prefix.count <= candidate.count && candidate.starts(with: prefix)
        }
    }

    private static func isCPRResponse(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        guard bytes[0] == esc, bytes[1] == 0x5B, bytes.last == 0x52 else { return false } // ESC [ ... R
        let payload = bytes.dropFirst(2).dropLast()
        let parts = payload.split(separator: 0x3B)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(isDigit) }
    }

    private static func parseOSCResponse(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 7 else { return nil }
        guard bytes[0] == esc, bytes[1] == 0x5D else { return nil } // ESC ]
        guard let separator = bytes.firstIndex(of: 0x3B), separator > 2 else { return nil } // ;
        let codeBytes = bytes[2..<separator]
        guard !codeBytes.isEmpty, codeBytes.allSatisfy(isDigit) else { return nil }
        guard hasOSCTerminator(bytes) else { return nil }
        return String(decoding: codeBytes, as: UTF8.self)
    }

    private static func hasOSCTerminator(_ bytes: [UInt8]) -> Bool {
        if bytes.last == bel {
            return true
        }
        return bytes.count >= 2 && bytes[bytes.count - 2] == esc && bytes.last == 0x5C
    }

    private static func hasPrefix(_ bytes: [UInt8], at index: Int, _ prefix: [UInt8]) -> Bool {
        guard index + prefix.count <= bytes.count else { return false }
        for offset in 0..<prefix.count where bytes[index + offset] != prefix[offset] {
            return false
        }
        return true
    }

    private static func makeOSCResponse(code: String, value: String) -> Data {
        Data("\u{1B}]\(code);\(value)\u{1B}\\".utf8)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}
