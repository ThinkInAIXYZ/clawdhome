// ClawdHomeHelper/Operations/ShellRunner.swift
// 同步执行外部命令的工具函数，Helper 内部使用

import Foundation
import Darwin

// MARK: - 可取消进程注册（供 cancelInit XPC 使用）

// 按日志路径（即按用户）记录受管进程，支持多用户并发初始化
private let _managedProcessLock = NSLock()
private var _managedProcesses: [String: Process] = [:]
/// URLSession 下载任务（NodeDownloader 注册），同 logPath 键
private var _managedDownloadTasks: [String: URLSessionDownloadTask] = [:]

/// 注册一个 URLSession 下载任务（供 NodeDownloader 调用）
func registerDownloadTask(_ task: URLSessionDownloadTask, logPath: String) {
    _managedProcessLock.lock()
    _managedDownloadTasks[logPath] = task
    _managedProcessLock.unlock()
}

/// 注销已完成/取消的下载任务
func unregisterDownloadTask(logPath: String) {
    _managedProcessLock.lock()
    _managedDownloadTasks.removeValue(forKey: logPath)
    _managedProcessLock.unlock()
}

/// 取消指定日志路径对应的受管进程和下载任务
/// logPath 为空时终止所有受管进程（兜底）
func terminateManagedProcess(logPath: String = "") {
    let processesToTerminate: [Process]
    let downloadsToCancel: [URLSessionDownloadTask]

    _managedProcessLock.lock()
    if logPath.isEmpty {
        processesToTerminate = Array(_managedProcesses.values)
        _managedProcesses.removeAll()
        downloadsToCancel = Array(_managedDownloadTasks.values)
        _managedDownloadTasks.removeAll()
    } else {
        processesToTerminate = _managedProcesses[logPath].map { [$0] } ?? []
        _managedProcesses.removeValue(forKey: logPath)
        downloadsToCancel = _managedDownloadTasks[logPath].map { [$0] } ?? []
        _managedDownloadTasks.removeValue(forKey: logPath)
    }
    _managedProcessLock.unlock()

    // 先取消下载任务，再终止进程树，确保“终止初始化”能真正停住 sudo/npm 及其子进程。
    downloadsToCancel.forEach { $0.cancel() }
    processesToTerminate.forEach { terminateProcessTree($0.processIdentifier) }
}

private func terminateProcessTree(_ rootPID: Int32) {
    guard rootPID > 0 else { return }
    let descendants = collectDescendantPIDs(of: rootPID)
    for pid in descendants.reversed() {
        _ = kill(pid, SIGTERM)
    }
    _ = kill(rootPID, SIGTERM)

    // 给进程一点时间优雅退出；超时后强制 SIGKILL。
    usleep(350_000)
    for pid in descendants.reversed() {
        _ = kill(pid, SIGKILL)
    }
    _ = kill(rootPID, SIGKILL)
}

/// 暴露给其它模块（如 XPC cancelInit）用于按 PID 终止整棵进程树。
func terminateProcessTreeByPID(_ rootPID: Int32) {
    terminateProcessTree(rootPID)
}

private func collectDescendantPIDs(of rootPID: Int32) -> [Int32] {
    var result: [Int32] = []
    var queue: [Int32] = [rootPID]

    while !queue.isEmpty {
        let current = queue.removeFirst()
        let childPIDs = directChildPIDs(of: current)
        if childPIDs.isEmpty { continue }
        result.append(contentsOf: childPIDs)
        queue.append(contentsOf: childPIDs)
    }
    return result
}

private func directChildPIDs(of parentPID: Int32) -> [Int32] {
    let output = (try? run("/usr/bin/pgrep", args: ["-P", "\(parentPID)"])) ?? ""
    if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return []
    }
    return output
        .split(whereSeparator: \.isNewline)
        .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .filter { $0 > 0 }
}

/// 同步运行外部命令，返回 stdout 字符串
/// - Throws: ShellError.nonZeroExit 若退出码非 0
@discardableResult
func run(_ executable: String, args: [String] = []) throws -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args

    let stdout = Pipe()
    let stderr = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stderr

    let stdoutData = NSMutableData()
    let stderrData = NSMutableData()
    let outputLock = NSLock()

    stdout.fileHandleForReading.readabilityHandler = { fh in
        let chunk = fh.availableData
        guard !chunk.isEmpty else { return }
        outputLock.lock()
        stdoutData.append(chunk)
        outputLock.unlock()
    }
    stderr.fileHandleForReading.readabilityHandler = { fh in
        let chunk = fh.availableData
        guard !chunk.isEmpty else { return }
        outputLock.lock()
        stderrData.append(chunk)
        outputLock.unlock()
    }

    try proc.run()
    proc.waitUntilExit()

    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil

    let stdoutTail = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrTail = stderr.fileHandleForReading.readDataToEndOfFile()
    outputLock.lock()
    stdoutData.append(stdoutTail)
    stderrData.append(stderrTail)
    let outData = stdoutData as Data
    let errData = stderrData as Data
    outputLock.unlock()

    let out = String(data: outData, encoding: .utf8) ?? ""
    let err = String(data: errData, encoding: .utf8) ?? ""

    guard proc.terminationStatus == 0 else {
        throw ShellError.nonZeroExit(
            command: ([executable] + args).joined(separator: " "),
            status: proc.terminationStatus,
            stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 执行命令，将命令行及 stdout+stderr 实时追加到日志文件
/// logURL 必须已存在（调用方负责创建）
@discardableResult
func runLogging(_ executable: String, args: [String] = [], logURL: URL) throws -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args

    // 先把命令行本身写入日志
    let cmdLine = "$ " + ([executable] + args).joined(separator: " ") + "\n"
    appendToLog(logURL, Data(cmdLine.utf8))

    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe  // stdout+stderr 合并，方便整体查看

    let accum = NSMutableData()
    let logFH = FileHandle(forWritingAtPath: logURL.path)
    logFH?.seekToEndOfFile()
    let logKey = logURL.path

    pipe.fileHandleForReading.readabilityHandler = { fh in
        let chunk = fh.availableData
        guard !chunk.isEmpty else { return }
        logFH?.write(chunk)
        accum.append(chunk)
    }

    _managedProcessLock.lock()
    if let existing = _managedProcesses[logKey], existing.isRunning {
        _managedProcessLock.unlock()
        pipe.fileHandleForReading.readabilityHandler = nil
        logFH?.closeFile()
        throw ShellError.processAlreadyRunning(logPath: logKey)
    }
    _managedProcesses[logKey] = proc
    _managedProcessLock.unlock()
    do {
        try proc.run()
    } catch {
        _managedProcessLock.lock()
        _managedProcesses.removeValue(forKey: logKey)
        _managedProcessLock.unlock()
        pipe.fileHandleForReading.readabilityHandler = nil
        logFH?.closeFile()
        throw error
    }

    proc.waitUntilExit()

    _managedProcessLock.lock()
    if _managedProcesses[logKey] === proc {
        _managedProcesses.removeValue(forKey: logKey)
    }
    _managedProcessLock.unlock()
    pipe.fileHandleForReading.readabilityHandler = nil

    // 排尽剩余数据
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty {
        logFH?.write(tail)
        accum.append(tail)
    }
    logFH?.closeFile()

    let output = String(data: accum as Data, encoding: .utf8) ?? ""
    guard proc.terminationStatus == 0 else {
        throw ShellError.nonZeroExit(
            command: ([executable] + args).joined(separator: " "),
            status: proc.terminationStatus,
            stderr: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func appendToLog(_ url: URL, _ data: Data) {
    guard let fh = FileHandle(forWritingAtPath: url.path) else { return }
    defer { fh.closeFile() }
    fh.seekToEndOfFile()
    fh.write(data)
}

/// dscl 快捷包装（固定使用本地目录节点，避免 Search 节点删除权限问题）
@discardableResult
func dscl(_ args: [String]) throws -> String {
    try dscl(auth: nil, args)
}

struct DirectoryAdminAuth {
    let user: String
    let password: String
}

/// 以目录管理员身份执行 dscl（auth 为空时按当前进程身份执行）
@discardableResult
func dscl(auth: DirectoryAdminAuth?, _ args: [String]) throws -> String {
    var fullArgs = ["/Local/Default"]
    if let auth {
        fullArgs += ["-u", auth.user, "-P", auth.password]
    }
    fullArgs += args
    return try run("/usr/bin/dscl", args: fullArgs)
}

enum ShellError: LocalizedError {
    case nonZeroExit(command: String, status: Int32, stderr: String)
    case processAlreadyRunning(logPath: String)

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(let cmd, let status, let stderr):
            return "命令失败 (exit \(status)): \(cmd)\n\(stderr)"
        case .processAlreadyRunning:
            return "已有初始化命令正在运行，请等待当前步骤完成或先终止初始化"
        }
    }
}

/// `launchctl bootout` 在目标 job 已不存在时会返回 exit 3，这属于幂等停止场景，可按成功处理。
func isIgnorableLaunchctlBootoutError(_ error: Error) -> Bool {
    guard case let ShellError.nonZeroExit(command, status, stderr) = error else { return false }
    guard status == 3 else { return false }

    let normalizedCommand = command.lowercased()
    guard normalizedCommand.contains("launchctl bootout") else { return false }

    let normalizedStderr = stderr.lowercased()
    if normalizedStderr.contains("no such process") {
        return true
    }
    if normalizedStderr.contains("could not find service") {
        return true
    }
    return false
}
