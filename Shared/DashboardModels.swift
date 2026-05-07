// Shared/DashboardModels.swift
import Foundation

struct MachineStats: Codable {
    var cpuPercent: Double        // 0-100
    var gpuPercent: Double?       // 0-100，nil = 无 GPU 或无法读取
    var memUsedMB: Double
    var memTotalMB: Double
    var diskUsedGB: Double
    var diskTotalGB: Double
    var cpuTempCelsius: Double?   // nil = 无法读取
}

struct ShrimpNetStats: Codable {
    var username: String
    var isRunning: Bool?          // gateway 是否运行
    var cpuPercent: Double?       // gateway 进程 CPU%（旧 Helper 无此字段）
    var memRssMB: Double?         // gateway 进程物理内存 MB
    var netBytesIn: UInt64        // 累计收到字节
    var netBytesOut: UInt64       // 累计发送字节
    var netRateInBps: Double      // 当前 bytes/sec
    var netRateOutBps: Double
    var memoryDirBytes: Int64     // ~/.openclaw/memory/ 总字节
    var openclawDirBytes: Int64   // ~/.openclaw/ 总字节（全量数据）
    var homeDirBytes: Int64       // ~/Users/<user>/ 总字节（家目录）
    var skillCount: Int           // ~/.openclaw/skills/ 文件数
    var gatewayPort: Int          // 实际使用的 gateway 端口（可能因冲突偏移）
}

struct DashboardSnapshot: Codable {
    var machine: MachineStats
    var shrimps: [ShrimpNetStats]
    var totalShrimpCount: Int
    var runningShrimpCount: Int
    var debugLog: String?            // 诊断日志（仅 Debug 构建填充）
    var connections: [ConnectionInfo] = []  // 活跃 TCP 连接列表
}

// MARK: - 每条活跃 TCP 连接

/// 单条 TCP 连接信息（由 ConnectionCollector 通过 proc_pidinfo 系统调用填充）
public struct ConnectionInfo: Codable, Identifiable, Sendable {
    public var id: String          // "\(soi_pcb)" — socket 唯一指针，生命周期内稳定
    public var username: String
    public var pid: Int32
    public var processName: String // proc_name() 结果，e.g. "node"

    public var localAddr: String   // "127.0.0.1:18502"
    public var remoteAddr: String  // "13.35.47.2:443"
    public var remoteHost: String? // 反向 DNS，异步填充，初始 nil

    public var state: String       // "ESTABLISHED" / "CLOSE_WAIT" / ...

    public var bytesIn: Int64      // tcpsi_rxbytes（本 socket 累计）
    public var bytesOut: Int64     // tcpsi_txbytes（本 socket 累计）
    public var rateIn: Double      // bytes/s，差分计算
    public var rateOut: Double
    public var isLoopback: Bool    // 是否为本地回环连接（127.x.x.x / ::1）
    public var proto: String       // "TCP" / "UDP"（默认 "TCP" 向后兼容）

    public init(id: String, username: String, pid: Int32, processName: String,
                localAddr: String, remoteAddr: String, remoteHost: String?,
                state: String, bytesIn: Int64, bytesOut: Int64,
                rateIn: Double, rateOut: Double, isLoopback: Bool = false,
                proto: String = "TCP") {
        self.id = id; self.username = username; self.pid = pid
        self.processName = processName; self.localAddr = localAddr
        self.remoteAddr = remoteAddr; self.remoteHost = remoteHost
        self.state = state; self.bytesIn = bytesIn; self.bytesOut = bytesOut
        self.rateIn = rateIn; self.rateOut = rateOut; self.isLoopback = isLoopback
        self.proto = proto
    }

    // 自定义解码：proto 字段不存在时默认 "TCP"（向后兼容旧 JSON）
    enum CodingKeys: String, CodingKey {
        case id, username, pid, processName, localAddr, remoteAddr, remoteHost
        case state, bytesIn, bytesOut, rateIn, rateOut, isLoopback, proto
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        pid = try c.decode(Int32.self, forKey: .pid)
        processName = try c.decode(String.self, forKey: .processName)
        localAddr = try c.decode(String.self, forKey: .localAddr)
        remoteAddr = try c.decode(String.self, forKey: .remoteAddr)
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost)
        state = try c.decode(String.self, forKey: .state)
        bytesIn = try c.decode(Int64.self, forKey: .bytesIn)
        bytesOut = try c.decode(Int64.self, forKey: .bytesOut)
        rateIn = try c.decode(Double.self, forKey: .rateIn)
        rateOut = try c.decode(Double.self, forKey: .rateOut)
        isLoopback = try c.decodeIfPresent(Bool.self, forKey: .isLoopback) ?? false
        proto = try c.decodeIfPresent(String.self, forKey: .proto) ?? "TCP"
    }
}

/// Gateway 服务就绪状态（由主 App HTTP 探活维护，与 Helper isRunning 互补）
enum GatewayReadiness: Equatable {
    case stopped   // launchctl 无 PID
    case starting  // 有 PID，/readyz 未通（含 healthz 无响应 < 60s）
    case ready     // /readyz 返回 HTTP 200
    case zombie    // 有 PID，/healthz 无响应超过 60s

    /// UI 显示文字
    var label: String {
        switch self {
        case .stopped:  "未运行"
        case .starting: "启动中…"
        case .ready:    "运行中"
        case .zombie:   "异常"
        }
    }
}
