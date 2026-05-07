// ClawdHomeHelper/Operations/ConnectionCollector.swift
// 通过 sysctl(net.inet.tcp.pcblist) 采集系统全部 TCP 连接，
// 再按 UID 过滤，关联到各虾用户。
// 零子进程、零 TTY 依赖，适合 root LaunchDaemon 环境。
//
// 原 proc_pidinfo(PROC_PIDFDSOCKETINFO) 方案已废弃：
// macOS 内核实际只写入 136 字节（旧结构体布局），而 Swift SDK 的
// socket_fdinfo 为 792 字节，关键字段全部超出内核写入范围。
//
// sysctl 方案：使用 xtcpcb64（64 位 macOS 标准导出格式）。
//
// ⚠️ xi_socket 字段偏移问题（经原始字节扫描确认）：
// 内核实际条目大小 xt_len=524，Swift SDK xtcpcb64 大小=472，差 52 字节。
// 差异位于 xinpcb64 内部，导致 xi_socket 字段（uid 等）实际偏移后移：
//   so_uid @ raw offset 512  ← 原始扫描 [512]=501 确认
//
// ⚠️ 流量统计改用 TCP 序列号（非 sb_cc 缓冲区占用量）：
// sb_cc 是 socket 缓冲区当前占用字节，数据被应用读走后即清零，
// 不适合用作流量计数器。snd_nxt/rcv_nxt 是单调递增的字节计数器：
//   snd_nxt @ raw offset 364  (Swift@312 + 52 = 364)  ← 发送字节
//   rcv_nxt @ raw offset 388  (Swift@336 + 52 = 388)  ← 接收字节
//   iss     @ raw offset 380  (Swift@328 + 52 = 380)  ← 初始发送序号
//   irs     @ raw offset 384  (Swift@332 + 52 = 384)  ← 初始接收序号
// 流量 = (snd_nxt &- iss) per connection，累加后差分计算速率。

import Darwin
import Foundation

// TCP state 整数 → 字符串（与内核 tcp_fsm.h 一致）
private let tcpStateNames: [Int32: String] = [
    0: "CLOSED", 1: "LISTEN", 2: "SYN_SENT", 3: "SYN_RCVD",
    4: "ESTABLISHED", 5: "CLOSE_WAIT", 6: "FIN_WAIT_1",
    7: "CLOSING", 8: "LAST_ACK", 9: "FIN_WAIT_2", 10: "TIME_WAIT"
]

/// 连接唯一键 → 上帧序列号缓存（用于差分计算速率）
private struct ConnFrameCache {
    var sndNxt: UInt32  // 上帧 snd_nxt
    var rcvNxt: UInt32  // 上帧 rcv_nxt
    var iss:    UInt32  // 初始发送序号（用于检测端口复用后的新连接）
    var irs:    UInt32  // 初始接收序号
    var seenAt: Date
}

/// 内部用：从 sysctl 解析出的原始 TCP 连接信息
private struct RawTCPEntry {
    var localIP:    String
    var localPort:  UInt16
    var remoteIP:   String
    var remotePort: UInt16
    var state:      Int32
    var uid:        uid_t
    var connId:     String   // "\(localIP):\(localPort)-\(remoteIP):\(remotePort)"，用作缓存键
    var sndNxt:     UInt32   // TCP 发送序号（单调递增）
    var rcvNxt:     UInt32   // TCP 接收序号（单调递增）
    var iss:        UInt32   // 初始发送序号，sndNxt &- iss = 本连接已发字节
    var irs:        UInt32   // 初始接收序号，rcvNxt &- irs = 本连接已收字节
}

/// 通过 sysctl net.inet.tcp.pcblist 采集 TCP 连接，零子进程，适合无头 daemon 环境
final class ConnectionCollector {

    // connId → 上帧序列号缓存（跨帧保留，连接消失后自动淘汰）
    private var frameCache: [String: ConnFrameCache] = [:]

    // 各 UID 自 Helper 启动以来的累计字节（单调递增，跨连接保留）
    private var userRxAcc: [uid_t: UInt64] = [:]
    private var userTxAcc: [uid_t: UInt64] = [:]

    // MARK: - 主接口

    /// 采集指定用户列表的 TCP 连接，返回 (连接列表, per-uid 累计字节)
    /// 在后台线程调用；调用方负责线程安全
    func collect(
        users: [(username: String, uid: uid_t)]
    ) -> (connections: [ConnectionInfo], uidBytes: [uid_t: (rx: UInt64, tx: UInt64)]) {
        let now = Date()

        // 1. 构建 uid → username 映射
        // 注：sysctl xtcpcb64 只含 UID，无法精确到单连接的 PID/进程名
        // 精确的每连接进程名需 NEFilterDataProvider（后续 Pro 功能）
        var uidUsername: [uid_t: String] = [:]
        for u in users { uidUsername[u.uid] = u.username }
        let targetUIDs = Set(users.map { $0.uid })

        // 2. 从 sysctl 获取所有 TCP 连接
        let rawEntries = readTCPConnections()
        helperLog("[conn] sysctl returned \(rawEntries.count) TCP entries system-wide",
                  level: .debug, channel: .diagnostics)

        // 3. 按 UID 过滤并组装 ConnectionInfo
        var allConnections: [ConnectionInfo] = []
        var uidBytesMap:    [uid_t: (rx: UInt64, tx: UInt64)] = [:]
        var seenConnIds = Set<String>()

        for uid in targetUIDs {
            let username    = uidUsername[uid] ?? "\(uid)"
            let userEntries = rawEntries.filter { $0.uid == uid }
            helperLog("[conn] uid=\(uid)(\(username)) TCP conns: \(userEntries.count)",
                      level: .debug, channel: .diagnostics)

            var rxDelta: UInt64 = 0
            var txDelta: UInt64 = 0

            for entry in userEntries {
                seenConnIds.insert(entry.connId)

                let loopback = isLoopbackAddr(entry.remoteIP) || isLoopbackAddr(entry.localIP)
                // LISTEN socket（remotePort=0）无实际数据传输，序列号字段可能为未初始化值，跳过差分
                let isListenSocket = entry.remotePort == 0

                // TCP 序列号差分：本连接在本帧间隔内新增的字节数
                let cached  = isListenSocket ? nil : frameCache[entry.connId]
                // ISS 变化说明端口被新 TCP 连接复用（旧连接关闭后重新握手），
                // 此时不能用旧缓存差分——否则 sndNxt 环绕会产生约 4GB 的虚假流量。
                let isNewConn = cached.map { $0.iss != entry.iss } ?? true
                let elapsed = (!isNewConn && cached != nil)
                    ? now.timeIntervalSince(cached!.seenAt) : 1.0
                // &- 是 32 位无符号环绕减法，正确处理序号回绕（约每 4GB 回绕一次）
                var dTx: UInt64 = (!isNewConn && cached != nil)
                    ? UInt64(entry.sndNxt &- cached!.sndNxt) : 0
                var dRx: UInt64 = (!isNewConn && cached != nil)
                    ? UInt64(entry.rcvNxt &- cached!.rcvNxt) : 0
                // 兜底：单连接单帧 delta 超过 500MB/s × 间隔 → 视为测量噪声丢弃
                let maxDelta = UInt64(500 * 1024 * 1024) * UInt64(max(elapsed, 1.0))
                if dTx > maxDelta { dTx = 0 }
                if dRx > maxDelta { dRx = 0 }
                let rateOut = elapsed > 0.1 ? Double(dTx) / elapsed : 0
                let rateIn  = elapsed > 0.1 ? Double(dRx) / elapsed : 0
                if !isListenSocket {
                    frameCache[entry.connId] = ConnFrameCache(
                        sndNxt: entry.sndNxt, rcvNxt: entry.rcvNxt,
                        iss: entry.iss, irs: entry.irs, seenAt: now
                    )
                }

                // loopback / LISTEN 连接不计入流量统计
                if !loopback && !isListenSocket {
                    rxDelta += dRx
                    txDelta += dTx
                }

                let localAddr  = "\(entry.localIP):\(entry.localPort)"
                let remoteAddr = "\(entry.remoteIP):\(entry.remotePort)"
                let state      = tcpStateNames[entry.state] ?? "STATE_\(entry.state)"
                // ConnectionInfo.bytesIn/Out 展示本连接累计字节（从连接建立起）
                // LISTEN socket 无实际传输，序列号字段可能是垃圾值，强制为 0
                let connTxBytes = isListenSocket ? Int64(0) : Int64(entry.sndNxt &- entry.iss)
                let connRxBytes = isListenSocket ? Int64(0) : Int64(entry.rcvNxt &- entry.irs)

                allConnections.append(ConnectionInfo(
                    id:          entry.connId,
                    username:    username,
                    pid:         -1,
                    processName: username,
                    localAddr:   localAddr,
                    remoteAddr:  remoteAddr,
                    remoteHost:  nil,
                    state:       state,
                    bytesIn:     connRxBytes,
                    bytesOut:    connTxBytes,
                    rateIn:      rateIn,
                    rateOut:     rateOut,
                    isLoopback:  loopback
                ))
            }

            // 累加到各 UID 的跨帧累计量（单调递增，供上层做差分）
            userRxAcc[uid, default: 0] += rxDelta
            userTxAcc[uid, default: 0] += txDelta
            uidBytesMap[uid] = (rx: userRxAcc[uid] ?? 0, tx: userTxAcc[uid] ?? 0)
        }

        // 淘汰本帧未见到的旧连接缓存
        frameCache = frameCache.filter { seenConnIds.contains($0.key) }

        return (allConnections, uidBytesMap)
    }

    // MARK: - 内部：sysctl 读取

    /// 调用 sysctl(net.inet.tcp.pcblist) 返回系统全部 TCP 连接
    /// 64 位 macOS 返回 xtcpcb64 格式；xinpgen 作为头尾分隔
    private func readTCPConnections() -> [RawTCPEntry] {
        // MIB: net.inet.tcp.pcblist — TCPCTL_PCBLIST = 11
        var mib: [CInt] = [CTL_NET, PF_INET, IPPROTO_TCP, 11]
        var needed = 0
        guard sysctl(&mib, 4, nil, &needed, nil, 0) == 0, needed > 0 else {
            helperLog("[conn] sysctl size query failed: errno=\(errno)",
                      level: .warn, channel: .diagnostics)
            return []
        }

        // 预留 25% 余量防止两次调用之间连接数增加
        var buf = [UInt8](repeating: 0, count: needed + needed / 4)
        var bufLen = buf.count
        guard sysctl(&mib, 4, &buf, &bufLen, nil, 0) == 0 else {
            helperLog("[conn] sysctl data read failed: errno=\(errno)",
                      level: .warn, channel: .diagnostics)
            return []
        }

        return parsePCBList(buf: buf, len: bufLen)
    }

    /// 解析 xtcpcb64 列表缓冲区
    /// 格式：xinpgen(头) + [xtcpcb64...] + xinpgen(尾)
    /// 每个条目的 xt_len 字段（UInt32，偏移 0）给出本条目字节数
    private func parsePCBList(buf: [UInt8], len: Int) -> [RawTCPEntry] {
        let headerSize = MemoryLayout<xinpgen>.size
        let entrySize  = MemoryLayout<xtcpcb64>.size
        guard len >= headerSize * 2 + entrySize else { return [] }

        return buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [RawTCPEntry] in
            guard let base = raw.baseAddress else { return [] }

            // 跳过头部 xinpgen
            let firstLen = base.load(as: UInt32.self)
            var offset = Int(firstLen)
            if offset < headerSize { offset = headerSize }

            var result: [RawTCPEntry] = []
            var loggedDelta = false

            while offset + 4 <= len {
                let entryLen = (base + offset).load(as: UInt32.self)

                // 尾部 xinpgen：xt_len == sizeof(xinpgen)
                if Int(entryLen) <= headerSize { break }
                // 防止越界或死循环
                guard Int(entryLen) >= entrySize, offset + Int(entryLen) <= len else { break }

                // 内核实际条目大小 - SDK 声明大小 = xinpcb64 内额外字节数（动态适配各 macOS 版本）
                let delta = Int(entryLen) - entrySize
                if !loggedDelta {
                    loggedDelta = true
                    let sdkOff = MemoryLayout<xtcpcb64>.offset(of: \.t_state) ?? -1
                    helperLog("[conn] entryLen=\(entryLen) sdkSize=\(entrySize) delta=\(delta) t_state_sdk=\(sdkOff) t_state_kernel=\(sdkOff+delta)",
                              level: .debug, channel: .diagnostics)
                    // 扫描 Int16 值在 0-10 范围内的偏移（定位 t_state）
                    let ep = base + offset
                    var hits = "[t-state-scan]"
                    for o in stride(from: 300, to: min(Int(entryLen), 450), by: 2) {
                        let v = ep.loadUnaligned(fromByteOffset: o, as: Int16.self)
                        if v >= 0 && v <= 10 { hits += " \(o):\(v)" }
                    }
                    helperLog(hits, level: .debug, channel: .diagnostics)
                }

                let entry    = (base + offset).load(as: xtcpcb64.self)
                let entryPtr = base + offset
                let vflag    = entry.xt_inpcb.inp_vflag

                // IPv4 (0x1) 或 IPv6 (0x2) 都处理
                if let parsed = parseEntry(entry, entryPtr: entryPtr, vflag: vflag, delta: delta) {
                    result.append(parsed)
                }
                offset += Int(entryLen)
            }
            helperLog("[conn] parsed \(result.count) entries (IPv4+IPv6)",
                      level: .debug, channel: .diagnostics)
            return result
        }
    }

    // MARK: - 内部：单条 xtcpcb64 解析

    private func parseEntry(_ e: xtcpcb64, entryPtr: UnsafeRawPointer, vflag: UInt8, delta: Int) -> RawTCPEntry? {
        let isIPv4 = (vflag & 0x1) != 0  // INP_IPV4
        let isIPv6 = (vflag & 0x2) != 0  // INP_IPV6
        guard isIPv4 || isIPv6 else { return nil }

        // 端口：位于条目前段，Swift 结构体字段偏移正确
        let remotePort = UInt16(bigEndian: e.xt_inpcb.inp_fport)
        let localPort  = UInt16(bigEndian: e.xt_inpcb.inp_lport)

        // xi_socket.so_uid：SDK 偏移 460 + delta（额外字节数）= 内核实际偏移
        // 原始扫描确认：delta=52 时 uid 在 offset 512
        let uid = uid_t(entryPtr.loadUnaligned(fromByteOffset: 460 + delta, as: UInt32.self))

        // TCP 序列号：SDK 基础偏移 + delta = 内核实际偏移（通过全字段扫描确认）
        //   snd_nxt SDK@348 + delta(52) → Kernel@400
        //   iss     SDK@280 + delta(52) → Kernel@332
        //   rcv_nxt SDK@268 + delta(52) → Kernel@320
        //   irs     SDK@272 + delta(52) → Kernel@324
        let sndNxt = entryPtr.loadUnaligned(fromByteOffset: 348 + delta, as: UInt32.self)
        let rcvNxt = entryPtr.loadUnaligned(fromByteOffset: 268 + delta, as: UInt32.self)
        let iss    = entryPtr.loadUnaligned(fromByteOffset: 280 + delta, as: UInt32.self)
        let irs    = entryPtr.loadUnaligned(fromByteOffset: 272 + delta, as: UInt32.self)
        // t_state 同样受 delta 偏移影响，需手动计算实际偏移
        let stateRaw = entryPtr.loadUnaligned(
            fromByteOffset: MemoryLayout<xtcpcb64>.offset(of: \.t_state)! + delta,
            as: Int32.self)

        let remoteIP: String
        let localIP:  String

        if isIPv4 {
            // IPv4 地址在 ia46_addr4（跳过 12 字节 padding）
            var fAddr = e.xt_inpcb.inp_dependfaddr.inp46_foreign.ia46_addr4
            var lAddr = e.xt_inpcb.inp_dependladdr.inp46_local.ia46_addr4
            var fBuf  = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var lBuf  = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &fAddr, &fBuf, socklen_t(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &lAddr, &lBuf, socklen_t(INET_ADDRSTRLEN))
            remoteIP = String(cString: fBuf)
            localIP  = String(cString: lBuf)
        } else {
            // IPv6：inet_ntop 可能产生 IPv4-mapped(::ffff:x.x.x.x) 或
            // IPv4-compatible(::x.x.x.x) 格式，统一展开为普通 IPv4
            var fAddr6 = e.xt_inpcb.inp_dependfaddr.inp6_foreign
            var lAddr6 = e.xt_inpcb.inp_dependladdr.inp6_local
            var fBuf   = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var lBuf   = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &fAddr6, &fBuf, socklen_t(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &lAddr6, &lBuf, socklen_t(INET6_ADDRSTRLEN))
            remoteIP = normalizeIPv6(String(cString: fBuf))
            localIP  = normalizeIPv6(String(cString: lBuf))
        }

        return RawTCPEntry(
            localIP:    localIP,
            localPort:  localPort,
            remoteIP:   remoteIP,
            remotePort: remotePort,
            state:      stateRaw,
            uid:        uid,
            connId:     "\(localIP):\(localPort)-\(remoteIP):\(remotePort)",
            sndNxt:     sndNxt,
            rcvNxt:     rcvNxt,
            iss:        iss,
            irs:        irs
        )
    }

    // MARK: - 工具

    /// IPv4-mapped(::ffff:x.x.x.x) 或 IPv4-compatible(::x.x.x.x) → 纯 IPv4 字符串
    private func normalizeIPv6(_ ip: String) -> String {
        if ip.hasPrefix("::ffff:") { return String(ip.dropFirst(7)) }
        if ip.hasPrefix("::") {
            let rest = String(ip.dropFirst(2))
            if rest.split(separator: ".").count == 4 { return rest }
        }
        return ip
    }

    /// 判断 IP 地址是否为 loopback（127.0.0.0/8、::1、IPv4-mapped ::ffff:127.x）
    private func isLoopbackAddr(_ ip: String) -> Bool {
        if ip.hasPrefix("127.") || ip == "::1" { return true }
        if ip.hasPrefix("::ffff:127.") { return true }
        return false
    }
}

// MARK: - NetworkCollectorProtocol

extension ConnectionCollector: NetworkCollectorProtocol {}
