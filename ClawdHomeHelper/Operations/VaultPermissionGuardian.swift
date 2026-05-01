import CoreServices
import Foundation

/// 共享目录权限守护：
/// - 事件驱动监听 /Users/Shared/ClawdHome 下变更
/// - 增量修复发生变化的文件/目录权限，避免高频全量扫描
final class VaultPermissionGuardian {
    static let shared = VaultPermissionGuardian()

    private let queue = DispatchQueue(label: "ai.clawdhome.vault-permission-guardian", qos: .utility)
    private var stream: FSEventStreamRef?
    private var started = false
    private var pendingPaths = Set<String>()
    private var flushWorkItem: DispatchWorkItem?

    private let sharedRoot = "/Users/Shared/ClawdHome"
    private let vaultsRoot = "/Users/Shared/ClawdHome/vaults"
    private let publicRoot = "/Users/Shared/ClawdHome/public"
    private let globalGroup = "clawdhome-all"

    private init() {}

    func startIfNeeded() {
        queue.async {
            guard !self.started else { return }
            self.started = true

            self.ensureDirectory(self.vaultsRoot)
            self.ensureDirectory(self.publicRoot)
            self.bootstrapFix()
            self.startEventStream()
        }
    }

    private func startEventStream() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, pathsPointer, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<VaultPermissionGuardian>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(pathsPointer, to: NSArray.self) as? [String] ?? []
            watcher.enqueue(paths: paths, count: count)
        }

        let watchedPaths = [vaultsRoot, publicRoot] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watchedPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            helperLog("[vault-guard] FSEventStreamCreate 失败", level: .error)
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            helperLog("[vault-guard] FSEventStreamStart 失败", level: .error)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
        helperLog("[vault-guard] 启动成功，监听 \(vaultsRoot) 与 \(publicRoot)")
    }

    private func enqueue(paths: [String], count: Int) {
        guard count > 0 else { return }
        for path in paths where isManagedPath(path) {
            pendingPaths.insert(path)
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPending()
        }
        flushWorkItem = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func flushPending() {
        guard !pendingPaths.isEmpty else { return }
        let paths = Array(pendingPaths)
        pendingPaths.removeAll()

        for path in paths {
            if path.hasPrefix(vaultsRoot + "/") {
                fixPrivatePath(path)
            } else if path == publicRoot || path.hasPrefix(publicRoot + "/") {
                fixPublicPath(path)
            } else if path == vaultsRoot {
                bootstrapFix()
            }
        }
    }

    private func bootstrapFix() {
        fixDirectoryTree(publicRoot, group: globalGroup, directoryMode: "2775", fileMode: "664", privateScope: false)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: vaultsRoot) else { return }
        for username in entries where !username.hasPrefix(".") {
            let path = "\(vaultsRoot)/\(username)"
            fixDirectoryTree(path, group: "clawdhome-\(username)", directoryMode: "2770", fileMode: "660", privateScope: true)
        }
    }

    private func fixPrivatePath(_ path: String) {
        let relative = String(path.dropFirst(vaultsRoot.count + 1))
        guard let username = relative.split(separator: "/").first.map(String.init), !username.isEmpty else { return }
        fixSinglePath(path, group: "clawdhome-\(username)", privateScope: true)
    }

    private func fixPublicPath(_ path: String) {
        fixSinglePath(path, group: globalGroup, privateScope: false)
    }

    private func fixSinglePath(_ path: String, group: String, privateScope: Bool) {
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        if isSymlink(path) { return }

        _ = try? run("/usr/bin/chgrp", args: [group, path])
        if isDir.boolValue {
            if privateScope {
                _ = try? run("/bin/chmod", args: ["u+rwx,g+rws,o-rwx", path])
            } else {
                _ = try? run("/bin/chmod", args: ["u+rwx,g+rws,o+rx", path])
            }
        } else {
            if privateScope {
                _ = try? run("/bin/chmod", args: ["u+rw,g+rw,o-rwx", path])
            } else {
                _ = try? run("/bin/chmod", args: ["u+rw,g+rw,o+r", path])
            }
        }
    }

    private func fixDirectoryTree(_ root: String, group: String, directoryMode: String, fileMode: String, privateScope: Bool) {
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return }

        _ = try? run("/usr/bin/chgrp", args: ["-R", group, root])
        _ = try? run("/usr/bin/find", args: [root, "-type", "d", "-exec", "/bin/chmod", directoryMode, "{}", "+"])
        _ = try? run("/usr/bin/find", args: [root, "-type", "f", "-exec", "/bin/chmod", fileMode, "{}", "+"])
        if privateScope {
            _ = try? run("/usr/bin/find", args: [root, "-exec", "/bin/chmod", "o-rwx", "{}", "+"])
        }
    }

    private func isManagedPath(_ path: String) -> Bool {
        path == vaultsRoot
            || path == publicRoot
            || path.hasPrefix(vaultsRoot + "/")
            || path.hasPrefix(publicRoot + "/")
    }

    private func ensureDirectory(_ path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    private func isSymlink(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType else { return false }
        return type == .typeSymbolicLink
    }
}

