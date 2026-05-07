// ClawdHomeHelper/Operations/NStatCollector.swift
// 通过 dlopen 加载 NetworkStatistics.framework（Activity Monitor 使用的同一套私有 API），
// 获取内核维护的 64-bit 精确字节计数器，覆盖 TCP + UDP + QUIC。
// 若 dlopen 失败（未来 macOS 移除该框架），DashboardCollector 自动 fallback 到 ConnectionCollector。

import Darwin
import Foundation

// MARK: - NStatSymbols（dlopen + dlsym 符号解析）

/// 从 dyld shared cache 加载 NetworkStatistics.framework 的 C 函数和 CFString 常量
struct NStatSymbols {

    // 框架 handle
    let handle: UnsafeMutableRawPointer

    // ── 函数指针 ──────────────────────────────────────────────────────────
    // NStatManagerRef NStatManagerCreate(CFAllocatorRef, dispatch_queue_t, void(^)(NStatSourceRef))
    let managerCreate:   @convention(c) (CFAllocator?, DispatchQueue, @escaping @convention(block) (NStatSourceRef) -> Void) -> NStatManagerRef
    let managerDestroy:  @convention(c) (NStatManagerRef) -> Void
    let managerAddAllTCP: @convention(c) (NStatManagerRef) -> Void
    let managerAddAllUDP: @convention(c) (NStatManagerRef) -> Void
    let managerQueryAllSources: @convention(c) (NStatManagerRef) -> Void

    // NStatSourceSetDescriptionBlock(NStatSourceRef, void(^)(CFDictionaryRef))
    let sourceSetDescriptionBlock: @convention(c) (NStatSourceRef, @escaping @convention(block) (CFDictionary) -> Void) -> Void
    // NStatSourceSetCountsBlock(NStatSourceRef, void(^)(CFDictionaryRef))
    let sourceSetCountsBlock: @convention(c) (NStatSourceRef, @escaping @convention(block) (CFDictionary) -> Void) -> Void
    // NStatSourceSetRemovedBlock(NStatSourceRef, void(^)())
    let sourceSetRemovedBlock: @convention(c) (NStatSourceRef, @escaping @convention(block) () -> Void) -> Void
    // NStatSourceQueryDescription(NStatSourceRef)
    let sourceQueryDescription: @convention(c) (NStatSourceRef) -> Void
    // NStatSourceQueryCounts(NStatSourceRef)
    let sourceQueryCounts: @convention(c) (NStatSourceRef) -> Void

    // ── CFString 常量 key ────────────────────────────────────────────────
    let keyPID:         CFString
    let keyProcessName: CFString
    let keyLocal:       CFString
    let keyRemote:      CFString
    let keyRxBytes:     CFString
    let keyTxBytes:     CFString
    let keyTCPState:    CFString

    /// 尝试加载框架，任意符号缺失返回 nil
    static func load() -> NStatSymbols? {
        let path = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"
        guard let h = dlopen(path, RTLD_LAZY) else {
            helperLog("[nstat] dlopen failed: \(String(cString: dlerror()))",
                      level: .warn, channel: .diagnostics)
            return nil
        }

        // 辅助：获取函数指针，失败打日志返回 nil
        func sym<T>(_ name: String) -> T? {
            guard let p = dlsym(h, name) else {
                helperLog("[nstat] dlsym(\(name)) failed", level: .warn, channel: .diagnostics)
                return nil
            }
            return unsafeBitCast(p, to: T.self)
        }

        // 辅助：获取 CFString 常量（存储在全局变量中，需要 load(as:)）
        func key(_ name: String) -> CFString? {
            guard let p = dlsym(h, name) else {
                helperLog("[nstat] dlsym(\(name)) key failed", level: .warn, channel: .diagnostics)
                return nil
            }
            return p.load(as: CFString.self)
        }

        guard let create:     @convention(c) (CFAllocator?, DispatchQueue, @escaping @convention(block) (NStatSourceRef) -> Void) -> NStatManagerRef = sym("NStatManagerCreate"),
              let destroy:    @convention(c) (NStatManagerRef) -> Void = sym("NStatManagerDestroy"),
              let addTCP:     @convention(c) (NStatManagerRef) -> Void = sym("NStatManagerAddAllTCP"),
              let addUDP:     @convention(c) (NStatManagerRef) -> Void = sym("NStatManagerAddAllUDP"),
              let queryAll:   @convention(c) (NStatManagerRef) -> Void = sym("NStatManagerQueryAllSources"),
              let setDesc:    @convention(c) (NStatSourceRef, @escaping @convention(block) (CFDictionary) -> Void) -> Void = sym("NStatSourceSetDescriptionBlock"),
              let setCounts:  @convention(c) (NStatSourceRef, @escaping @convention(block) (CFDictionary) -> Void) -> Void = sym("NStatSourceSetCountsBlock"),
              let setRemoved: @convention(c) (NStatSourceRef, @escaping @convention(block) () -> Void) -> Void = sym("NStatSourceSetRemovedBlock"),
              let qDesc:      @convention(c) (NStatSourceRef) -> Void = sym("NStatSourceQueryDescription"),
              let qCounts:    @convention(c) (NStatSourceRef) -> Void = sym("NStatSourceQueryCounts"),
              let kPID         = key("kNStatSrcKeyPID"),
              let kProcessName = key("kNStatSrcKeyProcessName"),
              let kLocal       = key("kNStatSrcKeyLocal"),
              let kRemote      = key("kNStatSrcKeyRemote"),
              let kRxBytes     = key("kNStatSrcKeyRxBytes"),
              let kTxBytes     = key("kNStatSrcKeyTxBytes"),
              let kTCPState    = key("kNStatSrcKeyTCPState")
        else {
            dlclose(h)
            return nil
        }

        return NStatSymbols(
            handle: h,
            managerCreate: create, managerDestroy: destroy,
            managerAddAllTCP: addTCP, managerAddAllUDP: addUDP,
            managerQueryAllSources: queryAll,
            sourceSetDescriptionBlock: setDesc,
            sourceSetCountsBlock: setCounts,
            sourceSetRemovedBlock: setRemoved,
            sourceQueryDescription: qDesc,
            sourceQueryCounts: qCounts,
            keyPID: kPID, keyProcessName: kProcessName,
            keyLocal: kLocal, keyRemote: kRemote,
            keyRxBytes: kRxBytes, keyTxBytes: kTxBytes,
            keyTCPState: kTCPState
        )
    }
}

// MARK: - 不透明类型别名

/// NStatManagerRef / NStatSourceRef 是 C 不透明指针
typealias NStatManagerRef = UnsafeMutableRawPointer
typealias NStatSourceRef  = UnsafeMutableRawPointer

// MARK: - NStatCollector

/// 使用 NetworkStatistics.framework 采集 TCP+UDP 连接和流量字节
///
/// 所有可变状态仅在 callbackQueue（串行队列）上访问，保证线程安全。
/// collect() 通过 callbackQueue.sync 获取快照和执行状态更新。
final class NStatCollector: NetworkCollectorProtocol {

    private let symbols: NStatSymbols

    /// 串行队列：所有 NStatManager 回调和 collect() 的状态操作在此串行执行
    private let callbackQueue = DispatchQueue(label: "com.clawdhome.nstat", qos: .utility)

    /// NStatManager 实例（在 callbackQueue 上创建和销毁）
    private var manager: NStatManagerRef?

    /// 轮询定时器：异步触发 queryAllSources（不阻塞 callbackQueue）
    private var pollTimer: DispatchSourceTimer?

    // ── 以下所有状态仅在 callbackQueue 上访问 ──────────────────────────────

    /// 活跃连接状态，以 NStatSourceRef 的地址值为 key
    /// 指针地址在串行队列中安全：removed 回调必然先于同地址的 new source 回调
    private var activeSources: [Int: SourceState] = [:]

    /// 各 UID 自启动以来的累计字节（跨帧保留，单调递增）
    private var userRxAcc: [uid_t: UInt64] = [:]
    private var userTxAcc: [uid_t: UInt64] = [:]

    /// 上一帧各 source 的字节快照（用于计算 delta）
    private var prevSourceBytes: [Int: (rx: UInt64, tx: UInt64)] = [:]

    /// PID → UID 缓存（30 秒 TTL）
    private var pidUIDCache: [Int32: (uid: uid_t, expiry: Date)] = [:]
    private let pidCacheTTL: TimeInterval = 30

    init?(symbols: NStatSymbols) {
        self.symbols = symbols

        // 在 callbackQueue 上同步创建 manager
        var ok = false
        callbackQueue.sync {
            let mgr = symbols.managerCreate(kCFAllocatorDefault, self.callbackQueue) { [weak self] source in
                self?.handleNewSource(source)
            }
            self.manager = mgr
            // 注册 TCP 和 UDP 源
            symbols.managerAddAllTCP(mgr)
            symbols.managerAddAllUDP(mgr)
            ok = true
        }
        guard ok else { return nil }

        // 启动异步轮询定时器（每 0.8 秒触发一次 queryAllSources）
        // 必须在 callbackQueue 上异步执行，而非 collect() 的 sync 块中——
        // 因为 queryAllSources 内部通过 NWStatisticsManager 自己的串行队列遍历
        // 所有 source 并复制回调 block，如果某个 source 刚被内核发现但
        // handleNewSource 尚未在 callbackQueue 上执行（被 sync 阻塞），
        // 其 counts block 为 NULL，_Block_copy 会 SIGSEGV。
        // 使用异步定时器确保 handleNewSource 总是先于 queryAllSources 完成。
        let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
        timer.schedule(deadline: .now() + 0.8, repeating: 0.8)
        timer.setEventHandler { [weak self] in
            guard let self, let mgr = self.manager else { return }
            self.symbols.managerQueryAllSources(mgr)
        }
        timer.resume()
        pollTimer = timer

        helperLog("[nstat] NStatCollector initialized", level: .debug, channel: .diagnostics)
    }

    deinit {
        pollTimer?.cancel()
        if let mgr = manager {
            callbackQueue.sync {
                symbols.managerDestroy(mgr)
            }
        }
    }

    // MARK: - 新 source 回调（callbackQueue 上执行）

    private func handleNewSource(_ source: NStatSourceRef) {
        let key = Int(bitPattern: source)

        activeSources[key] = SourceState()

        symbols.sourceSetDescriptionBlock(source) { [weak self] dict in
            self?.handleDescription(sourceKey: key, dict: dict)
        }
        symbols.sourceSetCountsBlock(source) { [weak self] dict in
            self?.handleCounts(sourceKey: key, dict: dict)
        }
        symbols.sourceSetRemovedBlock(source) { [weak self] in
            self?.handleRemoved(sourceKey: key)
        }

        // 立即查询 description 和 counts
        symbols.sourceQueryDescription(source)
        symbols.sourceQueryCounts(source)
    }

    // MARK: - Description 回调（callbackQueue 上执行）

    private func handleDescription(sourceKey: Int, dict: CFDictionary) {
        let d = dict as NSDictionary
        guard var state = activeSources[sourceKey] else { return }

        if let pid = d[symbols.keyPID] as? Int32 {
            state.pid = pid
        }
        if let name = d[symbols.keyProcessName] as? String {
            state.processName = name
        }
        if let tcpState = d[symbols.keyTCPState] as? String {
            state.tcpState = tcpState
            state.proto = "TCP"
        } else {
            if state.proto == nil { state.proto = "UDP" }
        }

        if let localData = d[symbols.keyLocal] as? Data {
            state.localAddr = parseSockaddr(localData)
        }
        if let remoteData = d[symbols.keyRemote] as? Data {
            state.remoteAddr = parseSockaddr(remoteData)
        }

        activeSources[sourceKey] = state
    }

    // MARK: - Counts 回调（callbackQueue 上执行）

    private func handleCounts(sourceKey: Int, dict: CFDictionary) {
        let d = dict as NSDictionary
        guard var state = activeSources[sourceKey] else { return }

        if let rx = d[symbols.keyRxBytes] as? UInt64 {
            state.rxBytes = rx
        } else if let rx = d[symbols.keyRxBytes] as? Int64 {
            state.rxBytes = UInt64(bitPattern: rx)
        }
        if let tx = d[symbols.keyTxBytes] as? UInt64 {
            state.txBytes = tx
        } else if let tx = d[symbols.keyTxBytes] as? Int64 {
            state.txBytes = UInt64(bitPattern: tx)
        }

        activeSources[sourceKey] = state
    }

    // MARK: - Removed 回调（callbackQueue 上执行）

    private func handleRemoved(sourceKey: Int) {
        guard let state = activeSources.removeValue(forKey: sourceKey) else { return }

        // 计算未被 collect() 捕获的最终 delta，累加到 per-UID 累计器
        let prev = prevSourceBytes.removeValue(forKey: sourceKey) ?? (state.rxBytes, state.txBytes)
        let finalDeltaRx = state.rxBytes >= prev.rx ? state.rxBytes - prev.rx : 0
        let finalDeltaTx = state.txBytes >= prev.tx ? state.txBytes - prev.tx : 0

        if let uid = resolveUID(for: state) {
            userRxAcc[uid, default: 0] += finalDeltaRx
            userTxAcc[uid, default: 0] += finalDeltaTx
        }
    }

    // MARK: - collect（主接口，与 ConnectionCollector 签名一致）

    /// 采集指定用户列表的连接和累计字节
    ///
    /// queryAllSources 由独立的 pollTimer 异步触发（每 0.8 秒），回调在 callbackQueue 上更新 activeSources。
    /// collect() 仅 snapshot 当前已累积的状态，数据延迟 ≤1 秒，对仪表盘场景可接受。
    func collect(
        users: [(username: String, uid: uid_t)]
    ) -> (connections: [ConnectionInfo], uidBytes: [uid_t: (rx: UInt64, tx: UInt64)]) {
        let targetUIDs = Set(users.map(\.uid))
        var uidUsername: [uid_t: String] = [:]
        for u in users { uidUsername[u.uid] = u.username }

        // 所有状态读写在 callbackQueue.sync 内完成，保证与回调线程互斥
        var connections: [ConnectionInfo] = []
        var uidBytesMap: [uid_t: (rx: UInt64, tx: UInt64)] = [:]

        callbackQueue.sync {
            // 构建 per-UID 字节增量
            var uidDeltaRx: [uid_t: UInt64] = [:]
            var uidDeltaTx: [uid_t: UInt64] = [:]

            for (key, state) in activeSources {
                guard let uid = resolveUID(for: state),
                      targetUIDs.contains(uid) else { continue }

                let username = uidUsername[uid] ?? "\(uid)"
                let isLoopback = isLoopbackAddr(state.localAddr ?? "") || isLoopbackAddr(state.remoteAddr ?? "")
                let isListen = state.tcpState == "Listen" || (state.remoteAddr?.hasSuffix(":0") ?? false)

                // 计算帧间 delta
                let prev = prevSourceBytes[key] ?? (state.rxBytes, state.txBytes)
                var dRx = state.rxBytes >= prev.rx ? state.rxBytes - prev.rx : 0
                var dTx = state.txBytes >= prev.tx ? state.txBytes - prev.tx : 0
                let maxDelta: UInt64 = 500 * 1024 * 1024  // 500MB/s sanity cap
                if dRx > maxDelta { dRx = 0 }
                if dTx > maxDelta { dTx = 0 }

                if !isLoopback && !isListen {
                    uidDeltaRx[uid, default: 0] += dRx
                    uidDeltaTx[uid, default: 0] += dTx
                }

                let connId = "\(state.localAddr ?? "?")→\(state.remoteAddr ?? "?")"
                let proto = state.proto ?? "TCP"
                let tcpState = state.tcpState ?? (proto == "UDP" ? "UDP" : "UNKNOWN")

                connections.append(ConnectionInfo(
                    id: connId,
                    username: username,
                    pid: state.pid,
                    processName: state.processName ?? "(\(state.pid))",
                    localAddr: state.localAddr ?? "?",
                    remoteAddr: state.remoteAddr ?? "?",
                    remoteHost: nil,
                    state: tcpState,
                    bytesIn: Int64(state.rxBytes),
                    bytesOut: Int64(state.txBytes),
                    rateIn: 0,  // DashboardCollector 负责 EMA 平滑
                    rateOut: 0,
                    isLoopback: isLoopback,
                    proto: proto
                ))
            }

            // 更新 prevSourceBytes 为当前值
            for (key, state) in activeSources {
                prevSourceBytes[key] = (state.rxBytes, state.txBytes)
            }

            // 累加 delta 到 per-UID 累计器
            for uid in targetUIDs {
                userRxAcc[uid, default: 0] += uidDeltaRx[uid, default: 0]
                userTxAcc[uid, default: 0] += uidDeltaTx[uid, default: 0]
                uidBytesMap[uid] = (rx: userRxAcc[uid] ?? 0, tx: userTxAcc[uid] ?? 0)
            }
        }

        return (connections, uidBytesMap)
    }

    // MARK: - PID → UID 映射（callbackQueue 上调用）

    private func resolveUID(for state: SourceState) -> uid_t? {
        let pid = state.pid
        guard pid > 0 else { return nil }

        let now = Date()
        if let cached = pidUIDCache[pid], cached.expiry > now {
            return cached.uid
        }

        var bsdInfo = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, size) == size else {
            return nil
        }
        let uid = bsdInfo.pbi_uid
        pidUIDCache[pid] = (uid, now.addingTimeInterval(pidCacheTTL))
        return uid
    }

    // MARK: - sockaddr 解析

    /// 将 sockaddr Data 解析为 "ip:port" 字符串
    private func parseSockaddr(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }

        return data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let family = base.load(fromByteOffset: 1, as: UInt8.self)  // sa_family at offset 1

            if family == UInt8(AF_INET) {
                guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                var sa = sockaddr_in()
                withUnsafeMutableBytes(of: &sa) { dest in
                    dest.copyBytes(from: raw.prefix(MemoryLayout<sockaddr_in>.size))
                }
                var addr = sa.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let port = UInt16(bigEndian: sa.sin_port)
                return "\(String(cString: buf)):\(port)"
            } else if family == UInt8(AF_INET6) {
                guard data.count >= MemoryLayout<sockaddr_in6>.size else { return nil }
                var sa = sockaddr_in6()
                withUnsafeMutableBytes(of: &sa) { dest in
                    dest.copyBytes(from: raw.prefix(MemoryLayout<sockaddr_in6>.size))
                }
                var addr = sa.sin6_addr
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                let port = UInt16(bigEndian: sa.sin6_port)
                return "\(String(cString: buf)):\(port)"
            }
            return nil
        }
    }

    // MARK: - 工具

    private func isLoopbackAddr(_ addr: String) -> Bool {
        if addr.hasPrefix("127.") || addr.hasPrefix("::1:") || addr == "::1" { return true }
        if addr.hasPrefix("::ffff:127.") { return true }
        return false
    }
}

// MARK: - SourceState（内部类型）

private struct SourceState {
    var pid: Int32 = -1
    var processName: String?
    var localAddr: String?
    var remoteAddr: String?
    var tcpState: String?
    var proto: String?       // "TCP" / "UDP"
    var rxBytes: UInt64 = 0
    var txBytes: UInt64 = 0
}
