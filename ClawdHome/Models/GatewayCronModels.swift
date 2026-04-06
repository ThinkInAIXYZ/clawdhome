// 简化自 openclaw/apps/macos/Sources/OpenClaw/CronModels.swift

import Foundation

// MARK: - GatewayCronSchedule

enum GatewayCronSchedule: Codable, Equatable {
    case at(at: String)
    case every(everyMs: Int, anchorMs: Int?)
    case cron(expr: String, tz: String?)

    enum CodingKeys: String, CodingKey {
        case kind, at, atMs, everyMs, anchorMs, expr, tz
    }

    var kind: String {
        switch self {
        case .at: "at"
        case .every: "every"
        case .cron: "cron"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "at":
            if let at = try container.decodeIfPresent(String.self, forKey: .at),
               !at.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                self = .at(at: at)
                return
            }
            if let atMs = try container.decodeIfPresent(Int.self, forKey: .atMs) {
                let date = Date(timeIntervalSince1970: TimeInterval(atMs) / 1000)
                self = .at(at: Self.formatIsoDate(date))
                return
            }
            throw DecodingError.dataCorruptedError(
                forKey: .at,
                in: container,
                debugDescription: "Missing schedule.at")
        case "every":
            self = try .every(
                everyMs: container.decode(Int.self, forKey: .everyMs),
                anchorMs: container.decodeIfPresent(Int.self, forKey: .anchorMs))
        case "cron":
            self = try .cron(
                expr: container.decode(String.self, forKey: .expr),
                tz: container.decodeIfPresent(String.self, forKey: .tz))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown schedule kind: \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        switch self {
        case let .at(at):
            try container.encode(at, forKey: .at)
        case let .every(everyMs, anchorMs):
            try container.encode(everyMs, forKey: .everyMs)
            try container.encodeIfPresent(anchorMs, forKey: .anchorMs)
        case let .cron(expr, tz):
            try container.encode(expr, forKey: .expr)
            try container.encodeIfPresent(tz, forKey: .tz)
        }
    }

    static func parseAtDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let date = makeIsoFormatter(withFractional: true).date(from: trimmed) { return date }
        return makeIsoFormatter(withFractional: false).date(from: trimmed)
    }

    static func formatIsoDate(_ date: Date) -> String {
        makeIsoFormatter(withFractional: false).string(from: date)
    }

    private static func makeIsoFormatter(withFractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    // MARK: 序列化为 RPC 参数字典

    func toDict() -> [String: Any] {
        switch self {
        case let .at(at):
            return ["kind": "at", "at": at]
        case let .every(everyMs, anchorMs):
            var dict: [String: Any] = ["kind": "every", "everyMs": everyMs]
            if let anchorMs { dict["anchorMs"] = anchorMs }
            return dict
        case let .cron(expr, tz):
            var dict: [String: Any] = ["kind": "cron", "expr": expr]
            if let tz { dict["tz"] = tz }
            return dict
        }
    }
}

// MARK: - GatewayCronPayload

enum GatewayCronPayload: Codable, Equatable {
    case systemEvent(text: String)
    case agentTurn(
        message: String,
        thinking: String?,
        timeoutSeconds: Int?,
        deliver: Bool?,
        channel: String?,
        to: String?,
        bestEffortDeliver: Bool?)

    enum CodingKeys: String, CodingKey {
        case kind, text, message, thinking, timeoutSeconds, deliver, channel, provider, to, bestEffortDeliver
    }

    var kind: String {
        switch self {
        case .systemEvent: "systemEvent"
        case .agentTurn: "agentTurn"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "systemEvent":
            self = try .systemEvent(text: container.decode(String.self, forKey: .text))
        case "agentTurn":
            self = try .agentTurn(
                message: container.decode(String.self, forKey: .message),
                thinking: container.decodeIfPresent(String.self, forKey: .thinking),
                timeoutSeconds: container.decodeIfPresent(Int.self, forKey: .timeoutSeconds),
                deliver: container.decodeIfPresent(Bool.self, forKey: .deliver),
                channel: container.decodeIfPresent(String.self, forKey: .channel)
                    ?? container.decodeIfPresent(String.self, forKey: .provider),
                to: container.decodeIfPresent(String.self, forKey: .to),
                bestEffortDeliver: container.decodeIfPresent(Bool.self, forKey: .bestEffortDeliver))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown payload kind: \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        switch self {
        case let .systemEvent(text):
            try container.encode(text, forKey: .text)
        case let .agentTurn(message, thinking, timeoutSeconds, deliver, channel, to, bestEffortDeliver):
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(thinking, forKey: .thinking)
            try container.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
            try container.encodeIfPresent(deliver, forKey: .deliver)
            try container.encodeIfPresent(channel, forKey: .channel)
            try container.encodeIfPresent(to, forKey: .to)
            try container.encodeIfPresent(bestEffortDeliver, forKey: .bestEffortDeliver)
        }
    }

    // MARK: 序列化为 RPC 参数字典

    func toDict() -> [String: Any] {
        switch self {
        case let .systemEvent(text):
            return ["kind": "systemEvent", "text": text]
        case let .agentTurn(message, thinking, timeoutSeconds, deliver, channel, to, bestEffortDeliver):
            var dict: [String: Any] = ["kind": "agentTurn", "message": message]
            if let thinking { dict["thinking"] = thinking }
            if let timeoutSeconds { dict["timeoutSeconds"] = timeoutSeconds }
            if let deliver { dict["deliver"] = deliver }
            if let channel { dict["channel"] = channel }
            if let to { dict["to"] = to }
            if let bestEffortDeliver { dict["bestEffortDeliver"] = bestEffortDeliver }
            return dict
        }
    }
}

// MARK: - GatewayCronJobState

struct GatewayCronJobState: Codable, Equatable {
    var nextRunAtMs: Int?
    var runningAtMs: Int?
    var lastRunAtMs: Int?
    var lastStatus: String?
    var lastError: String?
    var lastDurationMs: Int?
}

// MARK: - GatewayCronJob

struct GatewayCronJob: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var description: String?
    var enabled: Bool
    var deleteAfterRun: Bool?
    let createdAtMs: Int
    let updatedAtMs: Int
    let schedule: GatewayCronSchedule
    /// "main" / "isolated" / "current" 或 "session:<id>"
    let sessionTarget: String
    /// "now" / "next-heartbeat"
    let wakeMode: String
    let payload: GatewayCronPayload
    let state: GatewayCronJobState

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled job" : trimmed
    }

    var nextRunDate: Date? {
        guard let ms = state.nextRunAtMs else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    var lastRunDate: Date? {
        guard let ms = state.lastRunAtMs else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}

// MARK: - GatewayCronRunLogEntry

struct GatewayCronRunLogEntry: Codable, Identifiable {
    var id: String { "\(ts)-\(jobId)-\(action)" }

    let ts: Int
    let jobId: String
    let action: String
    let status: String?
    let error: String?
    let summary: String?
    let durationMs: Int?

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
    }
}

// MARK: - GatewayCronAddParams

/// 创建 Cron 任务的 RPC 参数，通过 toDict() 序列化后传入 JSON-RPC 请求
struct GatewayCronAddParams {
    let name: String
    let description: String?
    let enabled: Bool?
    let deleteAfterRun: Bool?
    let schedule: GatewayCronSchedule
    /// "main" / "isolated" / "current" 或 "session:<id>"
    let sessionTarget: String
    /// "now" / "next-heartbeat"
    let wakeMode: String
    let payload: GatewayCronPayload

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "schedule": schedule.toDict(),
            "sessionTarget": sessionTarget,
            "wakeMode": wakeMode,
            "payload": payload.toDict(),
        ]
        if let description { dict["description"] = description }
        if let enabled { dict["enabled"] = enabled }
        if let deleteAfterRun { dict["deleteAfterRun"] = deleteAfterRun }
        return dict
    }
}
