// ClawdHomeCLI/Formatting/Output.swift
// 输出格式化 — 表格（人类可读） + JSON（机器可读）

import Foundation

enum Output {
    static var jsonMode = false

    // MARK: - JSON 输出

    static func printJSON(_ value: Any) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    // MARK: - 表格输出

    static func printTable(headers: [String], rows: [[String]]) {
        guard !headers.isEmpty else { return }

        // 计算每列最大宽度
        var widths = headers.map { displayWidth($0) }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], displayWidth(cell))
            }
        }

        // 表头
        let headerLine = headers.enumerated().map { i, h in
            pad(h, to: widths[i])
        }.joined(separator: "  ")
        print(headerLine)

        // 数据行
        for row in rows {
            let line = row.enumerated().map { i, cell in
                i < widths.count ? pad(cell, to: widths[i]) : cell
            }.joined(separator: "  ")
            print(line)
        }
    }

    // MARK: - 单行状态

    static func printSuccess(_ message: String) {
        printErr("ok: \(message)")
    }

    static func printError(_ message: String) {
        printErr("error: \(message)")
    }

    static func printErr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    // MARK: - 私有

    private static func displayWidth(_ str: String) -> Int {
        // 简化：中文字符占 2 宽度
        var width = 0
        for scalar in str.unicodeScalars {
            if scalar.value > 0x7F {
                width += 2
            } else {
                width += 1
            }
        }
        return width
    }

    private static func pad(_ str: String, to width: Int) -> String {
        let current = displayWidth(str)
        if current >= width { return str }
        return str + String(repeating: " ", count: width - current)
    }
}
