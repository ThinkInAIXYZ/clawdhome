// ClawdHomeHelper/Operations/ProcessManager.swift
// 以 root 身份列出指定用户进程 + 发信号

import Foundation
import Darwin

enum ProcessManager {
    private static let portsCacheTTL: TimeInterval = 20
    private static let lsofTimeout: TimeInterval = 3
    private static let portsStateLock = NSLock()
    private static var portsCacheByUser: [String: (map: [Int32: [String]], updatedAt: Date)] = [:]
    private static var portsScanInProgress: Set<String> = []

    // MARK: - 进程列表

    /// 列出指定 macOS 用户名下的所有进程（含监听端口）
    static func listProcesses(username: String) -> [ProcessEntry] {
        listProcessSnapshot(username: username).entries
    }

    /// 列出进程快照：基础进程信息立即返回，端口信息通过缓存异步补齐
    static func listProcessSnapshot(username: String) -> ProcessListSnapshot {
        var entries = collectProcessesBasic(username: username)
        let now = Date()

        var cachedPortMap: [Int32: [String]] = [:]
        var portsLoading = false
        var shouldStartScan = false

        portsStateLock.lock()
        if let cached = portsCacheByUser[username] {
            cachedPortMap = cached.map
            if now.timeIntervalSince(cached.updatedAt) > portsCacheTTL,
               !portsScanInProgress.contains(username) {
                portsScanInProgress.insert(username)
                shouldStartScan = true
                portsLoading = true
            }
        } else {
            if !portsScanInProgress.contains(username) {
                portsScanInProgress.insert(username)
                shouldStartScan = true
            }
            portsLoading = true
        }
        if portsScanInProgress.contains(username) {
            portsLoading = true
        }
        portsStateLock.unlock()

        if shouldStartScan {
            startAsyncPortScan(username: username)
        }

        if !cachedPortMap.isEmpty {
            for i in entries.indices {
                entries[i].listeningPorts = cachedPortMap[entries[i].pid] ?? []
            }
        }

        return ProcessListSnapshot(entries: entries, portsLoading: portsLoading, updatedAt: now.timeIntervalSince1970)
    }

    private static func collectProcessesBasic(username: String) -> [ProcessEntry] {

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        // 字段顺序：pid ppid %cpu rss(KB) stat etime command
        // etime 格式 [[DD-]HH:]MM:SS，单 token；command 放最后，含空格也安全
        task.arguments = ["-U", username, "-o",
                          "pid=,ppid=,pcpu=,rss=,stat=,etime=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do { try task.run() } catch { return [] }
        task.waitUntilExit()

        let data   = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        var entries: [ProcessEntry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = String(line).trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            // 拆出前 6 个 token（pid ppid cpu rss stat etime），其余合并为 command
            let tokens = t.split(separator: " ", maxSplits: 6,
                                 omittingEmptySubsequences: true)
            guard tokens.count >= 6 else { continue }

            let pid    = Int32(tokens[0]) ?? 0
            let ppid   = Int32(tokens[1]) ?? 0
            let cpu    = Double(tokens[2]) ?? 0
            let rssKB  = Double(tokens[3]) ?? 0
            let stat   = String(tokens[4])
            let etime  = String(tokens[5])
            let cmd    = tokens.count > 6 ? String(tokens[6]) : ""

            // 取可执行文件短名
            let shortName: String = {
                let base = cmd.components(separatedBy: " ").first ?? cmd
                return base.components(separatedBy: "/").last ?? base
            }()

            entries.append(ProcessEntry(
                pid: pid, ppid: ppid,
                name: shortName, cmdline: cmd,
                cpuPercent: cpu,
                memRssMB: rssKB / 1024.0,
                state: stat, threads: 0,
                elapsedSeconds: parseEtime(etime),
                listeningPorts: []
            ))
        }
        return entries.sorted { $0.pid < $1.pid }
    }

    private static func startAsyncPortScan(username: String) {
        DispatchQueue.global(qos: .utility).async {
            let map = collectListeningPorts(username: username)
            portsStateLock.lock()
            portsCacheByUser[username] = (map, Date())
            portsScanInProgress.remove(username)
            portsStateLock.unlock()
        }
    }

    // MARK: - 监听端口（lsof）

    /// 收集该用户所有进程的监听/绑定端口（TCP LISTEN + UDP bound）
    /// 返回 pid -> ["tcp:80", "tcp:443", "udp:5353"]
    private static func collectListeningPorts(username: String) -> [Int32: [String]] {
        var result: [Int32: [String]] = [:]

        // TCP：仅 LISTEN 状态
        for (pid, addr) in runLsof(["-nP", "-a", "-u", username, "-iTCP", "-sTCP:LISTEN", "-F", "pn"]) {
            addPort(&result, pid: pid, addr: addr, proto: "tcp")
        }
        // UDP：bound 状态（过滤掉含 -> 的连接态，如 DNS 客户端查询）
        for (pid, addr) in runLsof(["-nP", "-a", "-u", username, "-iUDP", "-F", "pn"]) {
            guard !addr.contains("->") else { continue }
            addPort(&result, pid: pid, addr: addr, proto: "udp")
        }

        // 每个 pid：tcp 在前，udp 在后，各自按端口号升序
        return result.mapValues { ports in
            ports.sorted {
                let isTcpA = $0.hasPrefix("tcp"), isTcpB = $1.hasPrefix("tcp")
                if isTcpA != isTcpB { return isTcpA }
                let a = Int($0.components(separatedBy: ":").last ?? "") ?? 0
                let b = Int($1.components(separatedBy: ":").last ?? "") ?? 0
                return a < b
            }
        }
    }

    /// 运行 lsof，返回 (pid, n字段地址) 列表
    private static func runLsof(_ args: [String]) -> [(pid: Int32, addr: String)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do { try task.run() } catch { return [] }

        let deadline = Date().addingTimeInterval(lsofTimeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if task.isRunning {
            task.terminate()
            _ = try? pipe.fileHandleForReading.readToEnd()
            return []
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        var pairs: [(pid: Int32, addr: String)] = []
        var currentPID: Int32 = 0
        for line in output.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("p") {
                currentPID = Int32(s.dropFirst()) ?? 0
            } else if s.hasPrefix("n"), currentPID > 0 {
                pairs.append((pid: currentPID, addr: String(s.dropFirst())))
            }
        }
        return pairs
    }

    /// 从地址字符串提取端口并写入 result（去重）
    /// 地址格式：*:8080 / 127.0.0.1:3000 / [::]:443
    private static func addPort(_ result: inout [Int32: [String]],
                                 pid: Int32, addr: String, proto: String) {
        guard let portStr = addr.components(separatedBy: ":").last,
              let portNum = Int(portStr) else { return }
        let entry = "\(proto):\(portNum)"
        if result[pid] == nil {
            result[pid] = [entry]
        } else if !result[pid]!.contains(entry) {
            result[pid]!.append(entry)
        }
    }

    // MARK: - 信号

    /// 向指定 PID 发送信号（Helper 以 root 运行，可结束任意进程）
    /// signal: 15 = SIGTERM（优雅退出），9 = SIGKILL（强制结束）
    static func killProcess(pid: Int32, signal: Int32) -> Bool {
        Darwin.kill(pid, signal) == 0
    }

    // MARK: - 进程详情

    /// 查询单个 PID 的详情（含可执行文件元数据）
    static func processDetail(pid: Int32) -> ProcessDetail? {
        guard pid > 0 else { return nil }
        guard let entry = basicEntry(pid: pid) else { return nil }

        let procPath = executablePath(pid: pid)
        let fallbackPath = parseExecutablePath(from: entry.cmdline)
        let path = procPath ?? fallbackPath

        var exists = false
        var sizeBytes: Int64? = nil
        var createdAt: TimeInterval? = nil
        var modifiedAt: TimeInterval? = nil
        var accessedAt: TimeInterval? = nil
        var metadataChangedAt: TimeInterval? = nil
        var inode: UInt64? = nil
        var linkCount: UInt64? = nil
        var owner: String? = nil
        var permissions: String? = nil

        if let path {
            exists = FileManager.default.fileExists(atPath: path)
            if exists, let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                if let n = attrs[.size] as? NSNumber { sizeBytes = n.int64Value }
                if let d = attrs[.creationDate] as? Date { createdAt = d.timeIntervalSince1970 }
                if let d = attrs[.modificationDate] as? Date { modifiedAt = d.timeIntervalSince1970 }

                if let name = attrs[.ownerAccountName] as? String {
                    owner = name
                } else if let uid = attrs[.ownerAccountID] {
                    owner = "\(uid)"
                }

                if let mode = attrs[.posixPermissions] as? NSNumber {
                    permissions = String(format: "%03o", mode.intValue)
                }
            }

            var st = stat()
            if path.withCString({ stat($0, &st) }) == 0 {
                accessedAt = timeInterval(from: st.st_atimespec)
                metadataChangedAt = timeInterval(from: st.st_ctimespec)
                inode = UInt64(st.st_ino)
                linkCount = UInt64(st.st_nlink)
            }
        }

        // 单 PID 端口查询：更快，不依赖全量用户扫描
        var ports: [String] = []
        for (resultPID, addr) in runLsof(["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]) {
            guard resultPID == pid else { continue }
            if let p = portEntry(from: addr, proto: "tcp"), !ports.contains(p) { ports.append(p) }
        }
        for (resultPID, addr) in runLsof(["-nP", "-a", "-p", "\(pid)", "-iUDP", "-F", "pn"]) {
            guard resultPID == pid else { continue }
            guard !addr.contains("->") else { continue }
            if let p = portEntry(from: addr, proto: "udp"), !ports.contains(p) { ports.append(p) }
        }

        return ProcessDetail(
            pid: entry.pid,
            ppid: entry.ppid,
            name: entry.name,
            cmdline: entry.cmdline,
            cpuPercent: entry.cpuPercent,
            memRssMB: entry.memRssMB,
            state: entry.state,
            elapsedSeconds: entry.elapsedSeconds,
            startTime: processStartTime(pid: pid)?.timeIntervalSince1970,
            executablePath: path,
            executableExists: exists,
            executableFileSizeBytes: sizeBytes,
            executableCreatedAt: createdAt,
            executableModifiedAt: modifiedAt,
            executableAccessedAt: accessedAt,
            executableMetadataChangedAt: metadataChangedAt,
            executableInode: inode,
            executableLinkCount: linkCount,
            executableOwner: owner,
            executablePermissions: permissions,
            listeningPorts: ports.sorted()
        )
    }

    // MARK: - 私有：解析 etime

    // etime 格式：[[DD-]HH:]MM:SS
    private static func parseEtime(_ s: String) -> Int {
        var parts = s.components(separatedBy: ":")
        guard parts.count >= 2 else { return 0 }
        let secs = Int(parts.removeLast()) ?? 0
        let mins = Int(parts.removeLast()) ?? 0
        var hours = 0, days = 0
        if let rest = parts.first {
            let dp = rest.components(separatedBy: "-")
            if dp.count == 2 { days = Int(dp[0]) ?? 0; hours = Int(dp[1]) ?? 0 }
            else { hours = Int(rest) ?? 0 }
        }
        return days * 86400 + hours * 3600 + mins * 60 + secs
    }

    private static func basicEntry(pid: Int32) -> ProcessEntry? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "pid=,ppid=,pcpu=,rss=,stat=,etime=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = output.split(separator: "\n", omittingEmptySubsequences: true).first else { return nil }
        let t = String(line).trimmingCharacters(in: .whitespaces)
        let tokens = t.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard tokens.count >= 6 else { return nil }

        let pidValue = Int32(tokens[0]) ?? 0
        let ppid = Int32(tokens[1]) ?? 0
        let cpu = Double(tokens[2]) ?? 0
        let rssKB = Double(tokens[3]) ?? 0
        let stat = String(tokens[4])
        let etime = String(tokens[5])
        let cmd = tokens.count > 6 ? String(tokens[6]) : ""

        let shortName: String = {
            let base = cmd.components(separatedBy: " ").first ?? cmd
            return base.components(separatedBy: "/").last ?? base
        }()

        return ProcessEntry(
            pid: pidValue,
            ppid: ppid,
            name: shortName,
            cmdline: cmd,
            cpuPercent: cpu,
            memRssMB: rssKB / 1024.0,
            state: stat,
            threads: 0,
            elapsedSeconds: parseEtime(etime),
            listeningPorts: []
        )
    }

    private static func processStartTime(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    private static func executablePath(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    static func parseExecutablePath(from cmdline: String) -> String? {
        let s = cmdline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let candidate: String
        if s.first == "\"" {
            let afterFirst = s.index(after: s.startIndex)
            if let end = s[afterFirst...].firstIndex(of: "\"") {
                candidate = String(s[afterFirst..<end])
            } else {
                candidate = String(s.dropFirst())
            }
        } else {
            candidate = String(s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
        }
        guard candidate.hasPrefix("/") else { return nil }
        return candidate
    }

    private static func portEntry(from addr: String, proto: String) -> String? {
        guard let portStr = addr.components(separatedBy: ":").last,
              let portNum = Int(portStr) else { return nil }
        return "\(proto):\(portNum)"
    }

    private static func timeInterval(from timespec: timespec) -> TimeInterval {
        TimeInterval(timespec.tv_sec) + TimeInterval(timespec.tv_nsec) / 1_000_000_000
    }
}
