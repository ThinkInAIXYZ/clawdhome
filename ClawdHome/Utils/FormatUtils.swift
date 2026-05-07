// ClawdHome/Utils/FormatUtils.swift
import Foundation

enum FormatUtils {
    /// 将 bytes/sec 速率格式化为带单位字符串，如 "1.2 KB/s"
    static func formatBps(_ bps: Double) -> String {
        switch bps {
        case ..<1_000:       return String(format: "%.0f B/s", bps)
        case ..<1_000_000:   return String(format: "%.1f KB/s", bps / 1_000)
        default:             return String(format: "%.1f MB/s", bps / 1_000_000)
        }
    }

    /// 将字节数格式化为存储大小，如 "342.1 MB"
    static func formatBytes(_ bytes: Int64) -> String {
        switch bytes {
        case ..<1_024:           return "\(bytes) B"
        case ..<1_048_576:       return String(format: "%.0f KB", Double(bytes) / 1_024)
        case ..<1_073_741_824:   return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        default:                 return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
        }
    }

    /// 将累计 UInt64 字节格式化为简短显示
    static func formatTotalBytes(_ bytes: UInt64) -> String {
        formatBytes(Int64(min(bytes, UInt64(Int64.max))))
    }
}
