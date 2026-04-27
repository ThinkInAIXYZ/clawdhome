// ClawdHome/Utils/UserDeleteService.swift
// 用户删除操作的系统调用工具（nonisolated，不依赖 UI 状态）

import Foundation

enum UserDeleteService {

    enum CommandError: LocalizedError {
        case timeout
        var errorDescription: String? {
            switch self {
            case .timeout: return "command timeout"
            }
        }
    }

    /// 通过 sysadminctl 删除 macOS 用户
    static func deleteUserViaSysadminctl(
        username: String,
        keepHome: Bool,
        adminPassword: String
    ) async throws {
        let trimmed = adminPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HelperError.operationFailed(L10n.k("user.detail.auto.inputadminpassword", fallback: "请输入管理员登录密码"))
        }
        let timeoutSeconds: TimeInterval = 30

        try await Task.detached(priority: .userInitiated) {
            appLog("[user-delete] start @\(username) keepHome=\(keepHome)")

            let verifyArgs = ["-S", "-k", "-p", "", "-v"]
            let verify: (status: Int32, output: String)
            do {
                verify = try runProcessWithTimeout(
                    executable: "/usr/bin/sudo",
                    arguments: verifyArgs,
                    timeoutSeconds: timeoutSeconds,
                    stdin: "\(trimmed)\n"
                )
            } catch CommandError.timeout {
                appLog("[user-delete] command timeout @\(username)", level: .error)
                throw HelperError.operationFailed(L10n.k("user.detail.auto.admin", fallback: "管理员权限校验超时，请重试"))
            }

            if verify.status != 0 {
                let verifyOutput = verify.output
                let normalized = verifyOutput.lowercased()
                if normalized.contains("incorrect password") || normalized.contains("sorry, try again") {
                    throw HelperError.operationFailed(L10n.k("user.detail.auto.adminpassword", fallback: "管理员密码错误，请重试"))
                }
                if !verifyOutput.isEmpty {
                    throw HelperError.operationFailed(L10n.f("views.user_detail_view.text_0a32bf3a", fallback: "管理员权限校验失败：%@", String(describing: verifyOutput)))
                }
                throw HelperError.operationFailed(L10n.k("user.detail.auto.admin", fallback: "管理员权限校验失败"))
            }

            var sudoArgs = ["-S", "-p", "", "/usr/sbin/sysadminctl", "-deleteUser", username]
            if keepHome { sudoArgs.append("-keepHome") }

            let result = try runProcessWithTimeout(
                executable: "/usr/bin/sudo",
                arguments: sudoArgs,
                timeoutSeconds: timeoutSeconds,
                stdin: "\(trimmed)\n"
            )

            appLog("[user-delete] sysadminctl exit=\(result.status) outputBytes=\(result.output.utf8.count) @\(username)")
            if result.status != 0 {
                let output = result.output
                if output.lowercased().contains("unknown user") { return }
                if output.isEmpty {
                    throw HelperError.operationFailed(L10n.f("views.user_detail_view.sysa_minctl_exit", fallback: "删除用户失败：sysadminctl exit %@", String(describing: result.status)))
                }
                throw HelperError.operationFailed(L10n.f("views.user_detail_view.text_9d82e8aa", fallback: "删除用户失败：%@", String(describing: output)))
            }

            if !waitForUserRecordRemoval(username: username, retries: 40, sleepMs: 250) {
                appLog("[user-delete] record still exists after command @\(username)", level: .warn)
                throw HelperError.operationFailed(L10n.f("views.user_detail_view.text_a1027837", fallback: "删除用户 %@ 后校验失败：系统记录仍存在", String(describing: username)))
            }
            appLog("[user-delete] success @\(username)")
        }.value
    }

    // MARK: - 工具方法

    static func waitForUserRecordRemoval(username: String, retries: Int, sleepMs: UInt32) -> Bool {
        for _ in 0..<retries {
            if !userRecordExists(username: username) { return true }
            flushDirectoryCache()
            usleep(sleepMs * 1_000)
        }
        return !userRecordExists(username: username)
    }

    static func userRecordExists(username: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        proc.arguments = ["/Local/Default", "-read", "/Users/\(username)", "UniqueID"]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func flushDirectoryCache() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        proc.arguments = ["-flushcache"]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // best-effort
        }
    }

    static func runProcessWithTimeout(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        stdin: String? = nil
    ) throws -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let inputPipe = Pipe()
        proc.standardInput = inputPipe

        let buffer = ThreadSafeDataBuffer()
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
        }

        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        try proc.run()
        if let stdin {
            if let data = stdin.data(using: .utf8) {
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            }
        }
        inputPipe.fileHandleForWriting.closeFile()

        if sem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            if proc.isRunning { proc.terminate() }
            reader.readabilityHandler = nil
            throw CommandError.timeout
        }

        reader.readabilityHandler = nil
        let tail = reader.readDataToEndOfFile()
        buffer.append(tail)
        let data = buffer.snapshot()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, output)
    }

    // MARK: - 线程安全缓冲区

    final class ThreadSafeDataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) {
            lock.lock()
            storage.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            let data = storage
            lock.unlock()
            return data
        }
    }
}
