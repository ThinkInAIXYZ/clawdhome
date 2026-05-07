// ClawdHomeHelper/HelperImpl+Install.swift
// 安装管理 + 用户环境初始化 + 备份/恢复 + 克隆

import Foundation

extension ClawdHomeHelperImpl {

    func setConfig(username: String, key: String, value: String,
                   withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("配置变更 @\(username) \(key)=\(value)")
        do {
            let logURL = initLogURL(username: username)
            try ConfigWriter.setConfig(username: username, key: key, value: value, logURL: logURL)
            reply(true, nil)
        } catch {
            helperLog("配置变更失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func installOpenclaw(username: String, version: String?,
                         withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("安装 openclaw @\(username) v\(version ?? "latest")")
        let logURL = initLogURL(username: username)
        do {
            try InstallManager.install(username: username, version: version, logURL: logURL)

            // 升级后环境验证与修复
            let issues = InstallManager.verifyEnvironment(username: username)
            if !issues.isEmpty {
                helperLog("[post-install] 发现 \(issues.count) 个环境问题 @\(username): \(issues.map(\.id).joined(separator: ", "))", level: .warn)
                let (fixed, failed) = InstallManager.repairEnvironment(username: username, issues: issues)
                if !fixed.isEmpty {
                    helperLog("[post-install] 已修复: \(fixed.joined(separator: ", ")) @\(username)")
                }
                if !failed.isEmpty {
                    helperLog("[post-install] 未能修复: \(failed.joined(separator: ", ")) @\(username)", level: .warn)
                }
            }

            // 升级后刷新 LaunchDaemon plist（PATH 可能因 node 版本变化而改变）
            if let uid = try? UserManager.uid(for: username) {
                let (running, _) = GatewayManager.status(username: username, uid: uid)
                if running {
                    helperLog("[post-install] 网关运行中，重启以刷新 PATH @\(username)")
                    do {
                        try GatewayManager.restartGateway(username: username, uid: uid)
                        helperLog("[post-install] 网关重启成功 @\(username)")
                    } catch {
                        helperLog("[post-install] 网关重启失败 @\(username): \(error.localizedDescription)", level: .warn)
                    }
                }
            }

            reply(true, nil)
        } catch {
            helperLog("安装 openclaw 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func getOpenclawVersion(username: String, withReply reply: @escaping (String) -> Void) {
        reply(InstallManager.installedVersion(username: username) ?? "")
    }

    func reinstallOpenclaw(username: String, version: String?,
                           withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("重装 openclaw @\(username) v\(version ?? "latest")")
        let logURL = initLogURL(username: username)

        // 1. 停止网关（如果正在运行）
        var wasRunning = false
        if let uid = try? UserManager.uid(for: username) {
            let (running, _) = GatewayManager.status(username: username, uid: uid)
            wasRunning = running
            if running {
                helperLog("[reinstall] 停止网关 @\(username)")
                do {
                    try GatewayManager.stopGateway(username: username, uid: uid)
                } catch {
                    helperLog("[reinstall] 停止网关失败 @\(username): \(error.localizedDescription)", level: .warn)
                }
                // 等待网关退出
                for _ in 0..<20 {
                    let s = GatewayManager.status(username: username, uid: uid)
                    if !s.running { break }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }

        // 2. 清除旧的 openclaw 安装（仅清除 openclaw 包，不影响其他 npm 全局包）
        let openclawModulePath = "\(InstallManager.npmGlobalDir(for: username))/lib/node_modules/openclaw"
        let openclawBinPath = "\(InstallManager.npmGlobalBin(for: username))/openclaw"
        if FileManager.default.fileExists(atPath: openclawModulePath) {
            helperLog("[reinstall] 清除旧安装: \(openclawModulePath) @\(username)")
            try? FileManager.default.removeItem(atPath: openclawModulePath)
        }
        if FileManager.default.fileExists(atPath: openclawBinPath) {
            try? FileManager.default.removeItem(atPath: openclawBinPath)
        }

        // 3. 重新安装
        do {
            try InstallManager.install(username: username, version: version, logURL: logURL)
        } catch {
            helperLog("[reinstall] 重装失败 @\(username): \(error.localizedDescription)", level: .error)
            // 即使安装失败，也尝试重启网关
            if wasRunning, let uid = try? UserManager.uid(for: username) {
                try? GatewayManager.startGateway(username: username, uid: uid)
            }
            reply(false, error.localizedDescription)
            return
        }

        // 4. 验证环境
        let issues = InstallManager.verifyEnvironment(username: username)
        if !issues.isEmpty {
            helperLog("[reinstall] 重装后发现 \(issues.count) 个环境问题 @\(username)")
            let (fixed, failed) = InstallManager.repairEnvironment(username: username, issues: issues)
            if !fixed.isEmpty {
                helperLog("[reinstall] 已修复: \(fixed.joined(separator: ", ")) @\(username)")
            }
            if !failed.isEmpty {
                helperLog("[reinstall] 未能修复: \(failed.joined(separator: ", ")) @\(username)", level: .warn)
            }
        }

        // 5. 重启网关
        if wasRunning, let uid = try? UserManager.uid(for: username) {
            helperLog("[reinstall] 重启网关 @\(username)")
            do {
                try GatewayManager.startGateway(username: username, uid: uid)
            } catch {
                helperLog("[reinstall] 重启网关失败 @\(username): \(error.localizedDescription)", level: .warn)
                reply(true, "重装成功，但网关重启失败: \(error.localizedDescription)")
                return
            }
        }

        helperLog("[reinstall] 重装完成 @\(username)")
        reply(true, nil)
    }

    // MARK: 用户环境初始化

    /// 初始化日志路径，world-readable，供 app 实时读取
    private func initLogURL(username: String) -> URL {
        let path = "/tmp/clawdhome-init-\(username).log"
        // 确保文件存在且 world-readable（Helper 以 root 运行）
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil,
                attributes: [.posixPermissions: 0o644])
        }
        return URL(fileURLWithPath: path)
    }

    func installNode(username: String, nodeDistURL: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let logURL = initLogURL(username: username)
        let userNodePath = "/Users/\(username)/.brew/bin/node"

        func appendLog(_ msg: String) {
            if let fh = FileHandle(forWritingAtPath: logURL.path) {
                fh.seekToEndOfFile()
                fh.write(Data(msg.utf8))
                fh.closeFile()
            }
        }

        // 检查目标用户隔离 Node.js 是否已安装
        if NodeDownloader.isInstalled(for: username) {
            let version = (try? run(userNodePath, args: ["--version"]))
                ?? "(version unknown)"
            appendLog("✓ Node.js 已安装：\(version)\n")
            reply(true, nil)
            return
        }

        do {
            try NodeDownloader.install(username: username, distBaseURL: nodeDistURL, logURL: logURL)
            reply(true, nil)
        } catch {
            helperLog("安装 Node.js 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func isNodeInstalled(username: String, withReply reply: @escaping (Bool) -> Void) {
        reply(NodeDownloader.isInstalled(for: username))
    }

    func getXcodeEnvStatus(withReply reply: @escaping (String) -> Void) {
        let status = InstallManager.xcodeEnvStatus()
        let json = (try? JSONEncoder().encode(status)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        reply(json)
    }

    func installXcodeCommandLineTools(withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("触发 Xcode Command Line Tools 安装")
        do {
            try InstallManager.installXcodeCommandLineTools()
            reply(true, "已触发系统安装窗口，请按提示完成安装。")
        } catch {
            helperLog("触发 Xcode CLT 安装失败: \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func acceptXcodeLicense(withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("接受 Xcode license")
        do {
            try InstallManager.acceptXcodeLicense()
            reply(true, "已执行 license 接受。")
        } catch {
            helperLog("接受 Xcode license 失败: \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func setupNpmEnv(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let logURL = initLogURL(username: username)
        let npmGlobal = InstallManager.npmGlobalDir(for: username)
        let npmGlobalBin = InstallManager.npmGlobalBin(for: username)

        func appendLog(_ msg: String) {
            if let fh = FileHandle(forWritingAtPath: logURL.path) {
                fh.seekToEndOfFile()
                fh.write(Data(msg.utf8))
                fh.closeFile()
            }
        }

        guard getpwnam(username) != nil else {
            let message = "用户不存在：\(username)"
            appendLog("❌ \(message)\n")
            reply(false, message)
            return
        }

        do {
            // 1. 创建 ~/.npm-global 和 ~/.npm-global/bin 目录
            appendLog("$ mkdir -p \(npmGlobalBin)\n")
            try FileManager.default.createDirectory(
                atPath: npmGlobalBin,
                withIntermediateDirectories: true,
                attributes: [.ownerAccountName: username, .posixPermissions: 0o755]
            )
            try FilePermissionHelper.chownRecursive(npmGlobal, owner: username)
            appendLog("✓ 已创建 \(npmGlobal)\n")

            // 2. 将 npm 全局环境写入 ~/.zprofile（幂等）
            let profilePath = "/Users/\(username)/.zprofile"
            let existing = (try? String(contentsOfFile: profilePath, encoding: .utf8)) ?? ""
            let requiredExports = UserEnvContract.zprofileRequiredExports()
            let missingExports = requiredExports.filter { !existing.contains($0) }
            if !missingExports.isEmpty {
                var exportBlock = "\n"
                if !existing.contains("# npm global") {
                    exportBlock += "# npm global\n"
                }
                exportBlock += missingExports.joined(separator: "\n") + "\n"
                let data = Data(exportBlock.utf8)
                if FileManager.default.fileExists(atPath: profilePath) {
                    if let fh = FileHandle(forWritingAtPath: profilePath) {
                        fh.seekToEndOfFile()
                        fh.write(data)
                        fh.closeFile()
                    }
                } else {
                    try data.write(to: URL(fileURLWithPath: profilePath))
                    try FilePermissionHelper.chown(profilePath, owner: username)
                }
                appendLog("✓ 已将 npm global prefix/PATH 写入 ~/.zprofile\n")
            } else {
                appendLog("✓ ~/.zprofile 已包含 npm-global prefix + PATH 配置\n")
            }

            // 3. 确保 .zshrc 中 compinit 在 openclaw 补全脚本之前调用
            //    openclaw postinstall 会 append "source ~/.openclaw/completions/openclaw.zsh"，
            //    若 compinit 未事先初始化则 compdef 报错；此处提前写入，顺序正确
            let zshrcPath = "/Users/\(username)/.zshrc"
            let zshrcContent = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
            if !zshrcContent.contains("compinit") {
                let compLine = "\n# zsh completion init (required before openclaw completions)\nautoload -Uz compinit && compinit\n"
                let data = Data(compLine.utf8)
                if FileManager.default.fileExists(atPath: zshrcPath) {
                    if let fh = FileHandle(forWritingAtPath: zshrcPath) {
                        fh.seekToEndOfFile()
                        fh.write(data)
                        fh.closeFile()
                    }
                } else {
                    try data.write(to: URL(fileURLWithPath: zshrcPath))
                    try FilePermissionHelper.chown(zshrcPath, owner: username)
                }
                appendLog("✓ 已在 ~/.zshrc 中添加 compinit 初始化\n")
            } else {
                appendLog("✓ ~/.zshrc 已包含 compinit 配置\n")
            }

            // 4. 规范 openclaw completion 加载方式：仅在文件存在时 source，避免 reset 后报错
            var zshrcNormalized = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
            let lines = zshrcNormalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var filtered: [String] = []
            var skippingManagedBlock = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // 删除历史写入的 managed block，后续统一重建一份
                if trimmed == "# openclaw completion (safe-guarded)" {
                    skippingManagedBlock = true
                    continue
                }
                if skippingManagedBlock {
                    if trimmed == "fi" { skippingManagedBlock = false }
                    continue
                }

                // 删除旧的无保护 source（含绝对路径/波浪线两种）
                if trimmed == "source ~/.openclaw/completions/openclaw.zsh"
                    || trimmed == "source /Users/\(username)/.openclaw/completions/openclaw.zsh"
                    || (trimmed.hasPrefix("source ") && trimmed.contains(".openclaw/completions/openclaw.zsh")) {
                    continue
                }
                filtered.append(line)
            }

            zshrcNormalized = filtered.joined(separator: "\n")
            if !zshrcNormalized.hasSuffix("\n"), !zshrcNormalized.isEmpty {
                zshrcNormalized += "\n"
            }
            let completionBlock = """
                # openclaw completion (safe-guarded)
                if [ -f "$HOME/.openclaw/completions/openclaw.zsh" ]; then
                  source "$HOME/.openclaw/completions/openclaw.zsh"
                fi
                """
            if !zshrcNormalized.isEmpty { zshrcNormalized += "\n" }
            zshrcNormalized += completionBlock + "\n"

            if zshrcNormalized != zshrcContent {
                try Data(zshrcNormalized.utf8).write(to: URL(fileURLWithPath: zshrcPath))
                try FilePermissionHelper.chown(zshrcPath, owner: username)
                appendLog("✓ 已修复 openclaw 补全加载逻辑（文件不存在时不报错）\n")
            } else {
                appendLog("✓ openclaw 补全加载逻辑已是安全模式\n")
            }

            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func repairHomebrewPermission(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let logURL = initLogURL(username: username)
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let home = "/Users/\(username)"
        let profilePath = "\(home)/.zprofile"
        let sharedCacheRoot = "/var/lib/clawdhome/cache"
        let homebrewCacheDir = "\(sharedCacheRoot)/homebrew"
        let installScript = """
        set -e
        BREW_ROOT="$HOME/.brew"
        CACHE_DIR="/var/lib/clawdhome/cache/homebrew"
        CACHE_TAR="$CACHE_DIR/brew-master.tar.gz"
        PART_TAR="$CACHE_TAR.part.$USER.$$"
        BREW_TARBALL_URL="https://github.com/Homebrew/brew/tarball/master"
        CACHE_TTL_SECONDS=$((30 * 24 * 60 * 60))
        NOW_TS="$(date +%s)"

        mkdir -p "$BREW_ROOT" "$CACHE_DIR"

        extract_cached_tar() {
          tar -xzf "$CACHE_TAR" --strip 1 -C "$BREW_ROOT"
        }

        cache_fresh="0"
        if [ -s "$CACHE_TAR" ]; then
          CACHE_MTIME="$(stat -f %m "$CACHE_TAR" 2>/dev/null || echo 0)"
          CACHE_AGE=$((NOW_TS - CACHE_MTIME))
          if [ "$CACHE_AGE" -le "$CACHE_TTL_SECONDS" ] && [ "$CACHE_MTIME" -gt 0 ]; then
            cache_fresh="1"
            echo "✓ 使用 Homebrew 本地缓存（30 天内）：$CACHE_TAR"
            if ! extract_cached_tar; then
              echo "⚠ Homebrew 缓存损坏，删除后重新下载"
              rm -f "$CACHE_TAR"
              cache_fresh="0"
            fi
          else
            echo "ℹ Homebrew 缓存已过期（>${CACHE_TTL_SECONDS}s），重新下载"
            rm -f "$CACHE_TAR"
          fi
        fi

        if [ "$cache_fresh" != "1" ]; then
          rm -f "$PART_TAR"
          echo "⬇ 下载 Homebrew 到缓存..."
          curl --fail --show-error -L --connect-timeout 10 --max-time 180 --retry 2 --retry-delay 2 "$BREW_TARBALL_URL" -o "$PART_TAR"
          mv "$PART_TAR" "$CACHE_TAR"
          echo "✓ Homebrew 缓存写入完成"
          extract_cached_tar
        fi
        """
        let requiredExports = UserEnvContract.zprofileRequiredExports()

        func appendLog(_ msg: String) {
            if let fh = FileHandle(forWritingAtPath: logURL.path) {
                fh.seekToEndOfFile()
                fh.write(Data(msg.utf8))
                fh.closeFile()
            }
        }

        guard getpwnam(username) != nil else {
            let message = "用户不存在：\(username)"
            appendLog("❌ \(message)\n")
            reply(false, message)
            return
        }

        do {
            // 共享缓存目录给多用户初始化复用：所有用户可写，避免"第一只虾创建后其余用户不可写"。
            try FileManager.default.createDirectory(
                atPath: homebrewCacheDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            _ = try? FilePermissionHelper.chmod(sharedCacheRoot, mode: "1777")
            _ = try? FilePermissionHelper.chmod(homebrewCacheDir, mode: "1777")

            appendLog("\n▶ 修复 Homebrew 权限（普通用户目录安装）\n")
            appendLog("$ \(installScript)\n")
            let output = try runAsUser(
                username: username,
                nodePath: nodePath,
                command: "/bin/sh",
                args: ["-lc", installScript]
            )
            if !output.isEmpty {
                appendLog(output.hasSuffix("\n") ? output : "\(output)\n")
            }
            appendLog("✓ 已完成 ~/.brew 安装/更新\n")

            let existing = (try? String(contentsOfFile: profilePath, encoding: .utf8)) ?? ""
            let missingExports = requiredExports.filter { !existing.contains($0) }
            if !missingExports.isEmpty {
                var appendBlock = "\n"
                if !existing.contains("# user-local homebrew") {
                    appendBlock += "# user-local homebrew\n"
                }
                appendBlock += missingExports.joined(separator: "\n") + "\n"
                let data = Data(appendBlock.utf8)
                if FileManager.default.fileExists(atPath: profilePath) {
                    if let fh = FileHandle(forWritingAtPath: profilePath) {
                        fh.seekToEndOfFile()
                        fh.write(data)
                        fh.closeFile()
                    }
                } else {
                    try data.write(to: URL(fileURLWithPath: profilePath))
                }
                try FilePermissionHelper.chown(profilePath, owner: username)
                appendLog("✓ 已将 ~/.brew 环境变量写入 ~/.zprofile\n")
            } else {
                appendLog("✓ ~/.zprofile 已包含 ~/.brew 环境变量配置\n")
            }

            // 防御性修正：避免历史 root 执行导致目录归属错误
            _ = try? FilePermissionHelper.chownRecursive("\(home)/.brew", owner: username)
            // 确保 owner 对目录有 traverse 权限、对可执行文件有执行权限（修复 exit 126）
            _ = try? FilePermissionHelper.chmodSymbolicRecursive("\(home)/.brew", expr: "u+rwX")
            reply(true, nil)
        } catch {
            helperLog("修复 Homebrew 权限失败 @\(username): \(error.localizedDescription)", level: .warn)
            appendLog("❌ 修复 Homebrew 权限失败：\(error.localizedDescription)\n")
            reply(false, error.localizedDescription)
        }
    }

    func setNpmRegistry(username: String, registry: String,
                        withReply reply: @escaping (Bool, String?) -> Void) {
        // 早期验证：拒绝含换行符或非 https 的 registry URL，防止 .npmrc 注入
        let trimmed = registry.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\n") || trimmed.contains("\r")
            || !trimmed.lowercased().hasPrefix("https://") {
            helperLog("设置 npm 源拒绝 @\(username): 非法 URL", level: .warn)
            reply(false, "npm registry URL 必须为 https 协议且不含换行符")
            return
        }
        helperLog("设置 npm 源 @\(username): \(registry)")
        if !NodeDownloader.isInstalled(for: username) {
            let message = "Node.js 未安装就绪，暂不允许切换 npm 源"
            helperLog("设置 npm 源失败 @\(username): \(message)", level: .warn)
            reply(false, message)
            return
        }
        let logURL = initLogURL(username: username)
        do {
            _ = try InstallManager.setNpmRegistry(username: username, registry: registry, logURL: logURL)
            reply(true, nil)
        } catch {
            helperLog("设置 npm 源失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func getNpmRegistry(username: String, withReply reply: @escaping (String) -> Void) {
        reply(InstallManager.getNpmRegistry(username: username))
    }

    func cancelInit(username: String, withReply reply: @escaping (Bool) -> Void) {
        let logPath = "/tmp/clawdhome-init-\(username).log"
        terminateManagedProcess(logPath: logPath)
        terminateInitInstallCommands(username: username)
        reply(true)
    }

    /// 兜底终止初始化安装命令（例如 npm install -g --prefix /Users/<user>/.npm-global ...）。
    /// 作用：当受管进程映射丢失或父进程已变更时，仍可杀掉"最后执行的初始化命令"。
    private func terminateInitInstallCommands(username: String) {
        let patterns = [
            "npm install -g --prefix /Users/\(username)/.npm-global",
            "/usr/bin/sudo -u \(username) -H env PATH=",
        ]

        var pids = Set<Int32>()
        for pattern in patterns {
            let output = (try? run("/usr/bin/pgrep", args: ["-f", pattern])) ?? ""
            for line in output.split(whereSeparator: \.isNewline) {
                if let pid = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                    pids.insert(pid)
                }
            }
        }

        for pid in pids {
            terminateProcessTreeByPID(pid)
        }
    }

    func resetUserEnv(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("环境重置 @\(username)")
        let home = "/Users/\(username)"
        let targets = [InstallManager.npmGlobalDir(for: username), "\(home)/.openclaw"]
        var errors: [String] = []
        for path in targets {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                errors.append("\(path): \(error.localizedDescription)")
            }
        }
        if errors.isEmpty {
            reply(true, nil)
        } else {
            helperLog("环境重置失败 @\(username): \(errors.joined(separator: "; "))", level: .error)
            reply(false, errors.joined(separator: "\n"))
        }
    }

    func getGatewayURL(username: String, withReply reply: @escaping (String) -> Void) {
        guard let uid = try? UserManager.uid(for: username) else {
            reply(""); return
        }
        // 优先读配置文件中的实际端口（可能因冲突偏移），回退到 18000+uid 公式
        let port = GatewayManager.readConfiguredPort(username: username) ?? GatewayManager.port(for: uid)
        let base = "http://127.0.0.1:\(port)/"
        // 直接读取 JSON 文件获取 token（CLI config get 会脱敏敏感字段）
        if let token = ConfigWriter.getRawConfigValue(username: username, key: "gateway.auth.token"),
           !token.isEmpty {
            reply("\(base)#token=\(token)")
        } else {
            reply(base)
        }
    }

    func scanCloneClaw(username: String,
                      withReply reply: @escaping (String, String?) -> Void) {
        helperLog("克隆扫描 @\(username)")
        do {
            let result = try CloneClawManager.scanCloneItems(sourceUsername: username)
            let json = try CloneClawManager.encodeScanResult(result)
            reply(json, nil)
        } catch {
            helperLog("克隆扫描失败 @\(username): \(error.localizedDescription)", level: .error)
            reply("", error.localizedDescription)
        }
    }

    func cloneClaw(requestJSON: String,
                   withReply reply: @escaping (Bool, String, String?) -> Void) {
        helperLog("克隆新虾执行")
        do {
            let request = try CloneClawManager.decodeRequest(requestJSON)
            let targetUsername = request.targetUsername
            guard markCloneStarted(targetUsername: targetUsername) else {
                reply(false, "", "该目标用户已存在正在执行的克隆任务：\(targetUsername)")
                return
            }
            setCloneStatus(targetUsername: targetUsername, status: "准备克隆")

            DispatchQueue.global(qos: .userInitiated).async {
                defer { self.finishClone(targetUsername: targetUsername) }
                do {
                    let result = try self.executeCloneClaw(request)
                    let json = try CloneClawManager.encodeResult(result)
                    self.setCloneStatus(targetUsername: targetUsername, status: "克隆完成")
                    reply(true, json, nil)
                } catch {
                    self.setCloneStatus(targetUsername: targetUsername, status: "克隆失败：\(error.localizedDescription)")
                    helperLog("克隆执行失败: \(error.localizedDescription)", level: .error)
                    reply(false, "", error.localizedDescription)
                }
            }
        } catch {
            helperLog("克隆执行失败: \(error.localizedDescription)", level: .error)
            reply(false, "", error.localizedDescription)
        }
    }

    func cancelCloneClaw(targetUsername: String,
                         withReply reply: @escaping (Bool, String?) -> Void) {
        let username = targetUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            reply(false, "目标用户名不能为空")
            return
        }
        let requested = requestCloneCancel(targetUsername: username)
        if requested {
            setCloneStatus(targetUsername: username, status: "正在终止克隆…")
            helperLog("已请求终止克隆 @\(username)", level: .warn)
            reply(true, nil)
        } else {
            reply(false, "当前没有正在执行的克隆任务：\(username)")
        }
    }

    func getCloneClawStatus(targetUsername: String,
                            withReply reply: @escaping (String?) -> Void) {
        let username = targetUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            reply(nil)
            return
        }
        cloneControlLock.lock()
        let status = cloneStatusByTarget[username]
        cloneControlLock.unlock()
        reply(status)
    }

    // MARK: - 克隆内部实现

    private func executeCloneClaw(_ request: CloneClawRequest) throws -> CloneClawResult {
        setCloneStatus(targetUsername: request.targetUsername, status: "校验参数")
        try assertCloneNotCancelled(targetUsername: request.targetUsername)
        try CloneClawManager.validateUsername(request.targetUsername)
        guard !request.selectedItemIDs.isEmpty else { throw CloneClawManagerError.noItemsSelected }

        if getpwnam(request.targetUsername) != nil {
            throw CloneClawManagerError.targetUserExists(request.targetUsername)
        }

        setCloneStatus(targetUsername: request.targetUsername, status: "扫描可克隆数据")
        let scan = try CloneClawManager.scanCloneItems(sourceUsername: request.sourceUsername)
        let itemMap = Dictionary(uniqueKeysWithValues: scan.items.map { ($0.id, $0) })
        var selectedItems: [CloneScanItem] = []
        for itemID in request.selectedItemIDs {
            guard let item = itemMap[itemID] else {
                throw CloneClawManagerError.selectedItemNotFound(itemID)
            }
            guard item.selectable else {
                throw CloneClawManagerError.selectedItemDisabled(itemID)
            }
            selectedItems.append(item)
        }
        guard !selectedItems.isEmpty else { throw CloneClawManagerError.noItemsSelected }
        try assertCloneNotCancelled(targetUsername: request.targetUsername)

        let password = request.targetPassword?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.targetPassword!
            : generatedClonePassword()
        let sourceHome = try CloneClawManager.homeDirectory(for: request.sourceUsername)

        var createdTarget = false
        do {
            try assertCloneNotCancelled(targetUsername: request.targetUsername)
            setCloneStatus(targetUsername: request.targetUsername, status: "创建目标用户")
            try UserManager.createUser(
                username: request.targetUsername,
                fullName: request.targetFullName,
                password: password
            )
            createdTarget = true
            // 初始化安全文件夹（非阻塞）
            do { try VaultManager.setupVault(username: request.targetUsername) }
            catch { helperLog("Vault 自动初始化失败（克隆）@\(request.targetUsername): \(error.localizedDescription)", level: .warn) }

            let targetHome = try CloneClawManager.homeDirectory(for: request.targetUsername)
            let targetUID = try UserManager.uid(for: request.targetUsername)
            let targetGID = resolvedPrimaryGroupID(username: request.targetUsername)
            let shouldSanitizeConfig = selectedItems.contains(where: { $0.kind == .openclawConfig })
            let shouldEnsureShellInit = selectedItems.contains(where: { $0.kind == .envDirectory || $0.kind == .shellProfiles })
            for item in selectedItems {
                try assertCloneNotCancelled(targetUsername: request.targetUsername)
                setCloneStatus(targetUsername: request.targetUsername, status: "复制数据：\(item.title)")
                try copyCloneItem(
                    item,
                    sourceHome: sourceHome,
                    targetHome: targetHome,
                    cancelCheck: { [weak self] in
                        guard let self else { return }
                        try self.assertCloneNotCancelled(targetUsername: request.targetUsername)
                    }
                )
            }
            try assertCloneNotCancelled(targetUsername: request.targetUsername)
            if shouldSanitizeConfig {
                setCloneStatus(targetUsername: request.targetUsername, status: "清洗 openclaw.json")
                try sanitizeClonedConfig(
                    username: request.targetUsername,
                    uid: targetUID,
                    gid: targetGID
                )
            }
            try assertCloneNotCancelled(targetUsername: request.targetUsername)
            setCloneStatus(targetUsername: request.targetUsername, status: "修复权限")
            try fixCloneOwnership(
                username: request.targetUsername,
                uid: targetUID,
                gid: targetGID
            )
            if shouldEnsureShellInit {
                try assertCloneNotCancelled(targetUsername: request.targetUsername)
                setCloneStatus(targetUsername: request.targetUsername, status: "修复 Shell 初始化")
                try ensureCloneShellInit(username: request.targetUsername)
            }

            try assertCloneNotCancelled(targetUsername: request.targetUsername)
            setCloneStatus(targetUsername: request.targetUsername, status: "启动 Gateway")
            try GatewayManager.startGateway(username: request.targetUsername, uid: targetUID)
            // Gateway 启动会执行 openclaw config set，部分字段可能被回写为绝对路径。
            // 这里再做一次归一化，确保最终 openclaw.json 保持 ~/ 相对 home 的写法。
            if shouldSanitizeConfig {
                setCloneStatus(targetUsername: request.targetUsername, status: "归一化配置路径")
                try sanitizeClonedConfig(
                    username: request.targetUsername,
                    uid: targetUID,
                    gid: targetGID
                )
            }
            setCloneStatus(targetUsername: request.targetUsername, status: "整理结果")
            let gatewayURL = resolveCloneGatewayURL(username: request.targetUsername, uid: targetUID)

            return CloneClawResult(
                targetUsername: request.targetUsername,
                gatewayURL: gatewayURL,
                warnings: scan.warnings
            )
        } catch {
            if createdTarget {
                rollbackCloneUser(username: request.targetUsername)
            }
            throw error
        }
    }

    private func copyCloneItem(
        _ item: CloneScanItem,
        sourceHome: String,
        targetHome: String,
        cancelCheck: () throws -> Void
    ) throws {
        let fm = FileManager.default
        switch item.kind {
        case .envDirectory:
            let sourcePath = "\(sourceHome)/\(item.sourceRelativePath)"
            guard fm.fileExists(atPath: sourcePath) else {
                throw CloneClawManagerError.sourceItemMissing(item.sourceRelativePath)
            }
            let targetPath = "\(targetHome)/.npm-global"
            if fm.fileExists(atPath: targetPath) {
                try fm.removeItem(atPath: targetPath)
            }
            try copyCloneDirectory(from: sourcePath, to: targetPath, cancelCheck: cancelCheck)
        case .openclawConfig:
            try cancelCheck()
            let sourcePath = "\(sourceHome)/\(item.sourceRelativePath)"
            guard fm.fileExists(atPath: sourcePath) else {
                throw CloneClawManagerError.sourceItemMissing(item.sourceRelativePath)
            }
            try copyCloneFile(from: sourcePath, to: "\(targetHome)/.openclaw/openclaw.json")
        case .shellProfiles:
            let shellRelativePaths = [".zprofile", ".zshrc"]
            var copiedAny = false
            for relativePath in shellRelativePaths {
                try cancelCheck()
                let sourcePath = "\(sourceHome)/\(relativePath)"
                if fm.fileExists(atPath: sourcePath) {
                    try copyCloneFile(from: sourcePath, to: "\(targetHome)/\(relativePath)")
                    copiedAny = true
                }
            }
            if !copiedAny {
                throw CloneClawManagerError.sourceItemMissing(".zprofile/.zshrc")
            }
        case .secrets, .authProfiles:
            // 兼容旧请求：这两类克隆项已废弃
            throw CloneClawManagerError.selectedItemDisabled(item.id)
        case .roleData:
            let roleAgentRelativePath = ".openclaw/agents/main/agent"

            let roleAgentSource = "\(sourceHome)/\(roleAgentRelativePath)"
            var isRoleAgentDir: ObjCBool = false
            if fm.fileExists(atPath: roleAgentSource, isDirectory: &isRoleAgentDir), isRoleAgentDir.boolValue {
                let roleAgentTarget = "\(targetHome)/\(roleAgentRelativePath)"
                try fm.createDirectory(atPath: "\(targetHome)/.openclaw/agents/main", withIntermediateDirectories: true, attributes: nil)
                if fm.fileExists(atPath: roleAgentTarget) {
                    try fm.removeItem(atPath: roleAgentTarget)
                }
                try copyCloneDirectory(from: roleAgentSource, to: roleAgentTarget, cancelCheck: cancelCheck)
            } else {
                throw CloneClawManagerError.sourceItemMissing(roleAgentRelativePath)
            }
        }
    }

    private func copyCloneFile(from sourcePath: String, to targetPath: String) throws {
        let fm = FileManager.default
        let targetURL = URL(fileURLWithPath: targetPath)
        try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: targetPath) {
            try fm.removeItem(atPath: targetPath)
        }
        try fm.copyItem(atPath: sourcePath, toPath: targetPath)
    }

    private func copyCloneDirectory(from sourcePath: String, to targetPath: String, cancelCheck: () throws -> Void) throws {
        let fm = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let targetURL = URL(fileURLWithPath: targetPath)

        var isSourceDir: ObjCBool = false
        guard fm.fileExists(atPath: sourcePath, isDirectory: &isSourceDir), isSourceDir.boolValue else {
            throw CloneClawManagerError.sourceItemMissing(sourcePath)
        }

        try cancelCheck()
        if fm.fileExists(atPath: targetPath) {
            try fm.removeItem(atPath: targetPath)
        }
        try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return }

        for case let itemURL as URL in enumerator {
            try cancelCheck()
            let relativePath = itemURL.path.replacingOccurrences(of: sourceURL.path + "/", with: "")
            let destinationURL = targetURL.appendingPathComponent(relativePath)
            let values = try itemURL.resourceValues(forKeys: keys)

            if values.isDirectory == true {
                try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                continue
            }

            if values.isSymbolicLink == true {
                let dest = try fm.destinationOfSymbolicLink(atPath: itemURL.path)
                try fm.createSymbolicLink(atPath: destinationURL.path, withDestinationPath: dest)
                continue
            }

            if values.isRegularFile == true {
                try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: itemURL, to: destinationURL)
            }
        }
    }

    private func ensureCloneShellInit(username: String) throws {
        let profilePath = "/Users/\(username)/.zprofile"
        let zshrcPath = "/Users/\(username)/.zshrc"

        let existingProfile = (try? String(contentsOfFile: profilePath, encoding: .utf8)) ?? ""
        if !existingProfile.contains(".npm-global/bin") {
            let export = "\n# npm global\nexport PATH=\"$HOME/.npm-global/bin:$PATH\"\n"
            let data = Data(export.utf8)
            if FileManager.default.fileExists(atPath: profilePath) {
                if let fh = FileHandle(forWritingAtPath: profilePath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try data.write(to: URL(fileURLWithPath: profilePath))
            }
            try FilePermissionHelper.chown(profilePath, owner: username)
        }

        var zshrcContent = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        if !zshrcContent.contains("compinit") {
            let compLine = "\n# zsh completion init (required before openclaw completions)\nautoload -Uz compinit && compinit\n"
            let data = Data(compLine.utf8)
            if FileManager.default.fileExists(atPath: zshrcPath) {
                if let fh = FileHandle(forWritingAtPath: zshrcPath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try data.write(to: URL(fileURLWithPath: zshrcPath))
            }
            try FilePermissionHelper.chown(zshrcPath, owner: username)
            zshrcContent = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        }

        var zshrcNormalized = zshrcContent
        let lines = zshrcNormalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var filtered: [String] = []
        var skippingManagedBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# openclaw completion (safe-guarded)" {
                skippingManagedBlock = true
                continue
            }
            if skippingManagedBlock {
                if trimmed == "fi" { skippingManagedBlock = false }
                continue
            }
            if trimmed == "source ~/.openclaw/completions/openclaw.zsh"
                || trimmed == "source /Users/\(username)/.openclaw/completions/openclaw.zsh"
                || (trimmed.hasPrefix("source ") && trimmed.contains(".openclaw/completions/openclaw.zsh")) {
                continue
            }
            filtered.append(line)
        }

        zshrcNormalized = filtered.joined(separator: "\n")
        if !zshrcNormalized.hasSuffix("\n"), !zshrcNormalized.isEmpty {
            zshrcNormalized += "\n"
        }
        let completionBlock = """
            # openclaw completion (safe-guarded)
            if [ -f "$HOME/.openclaw/completions/openclaw.zsh" ]; then
              source "$HOME/.openclaw/completions/openclaw.zsh"
            fi
            """
        if !zshrcNormalized.isEmpty { zshrcNormalized += "\n" }
        zshrcNormalized += completionBlock + "\n"
        if zshrcNormalized != zshrcContent {
            try Data(zshrcNormalized.utf8).write(to: URL(fileURLWithPath: zshrcPath))
            try FilePermissionHelper.chown(zshrcPath, owner: username)
        }
    }

    private func sanitizeClonedConfig(username: String, uid: Int, gid: Int) throws {
        let path = "\(try CloneClawManager.homeDirectory(for: username))/.openclaw/openclaw.json"
        guard let data = FileManager.default.contents(atPath: path),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            return
        }
        guard let object = jsonObject as? [String: Any] else {
            throw CloneClawManagerError.invalidConfigFormat
        }
        let cleaned = CloneClawManager.sanitizeOpenclawConfig(object)
        let outData = try JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try outData.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FilePermissionHelper.chown(path, owner: "\(uid)", group: "\(gid)")
        try FilePermissionHelper.chmod(path, mode: "644")
    }

    private func fixCloneOwnership(username: String, uid: Int, gid: Int) throws {
        let home = try CloneClawManager.homeDirectory(for: username)
        let openclawPath = "\(home)/.openclaw"
        let npmGlobalPath = "\(home)/.npm-global"
        let owner = "\(uid)"
        let group = "\(gid)"

        try FilePermissionHelper.chown(home, owner: owner, group: group)
        try FilePermissionHelper.chmod(home, mode: "700")
        try assertOwnership(username: username, path: home)

        if FileManager.default.fileExists(atPath: openclawPath) {
            try FilePermissionHelper.chownRecursive(openclawPath, owner: "\(owner):\(group)")
            try FilePermissionHelper.chmod(openclawPath, mode: "700")
            try assertOwnership(username: username, path: openclawPath)
        }
        if FileManager.default.fileExists(atPath: npmGlobalPath) {
            try FilePermissionHelper.chownRecursive(npmGlobalPath, owner: "\(owner):\(group)")
            try assertOwnership(username: username, path: npmGlobalPath)
        }
    }

    private func resolvedPrimaryGroupID(username: String) -> Int {
        guard let pw = getpwnam(username) else { return 20 } // staff
        return Int(pw.pointee.pw_gid)
    }

    private func assertOwnership(username: String, path: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let owner = attrs[.ownerAccountName] as? String
        if owner != username {
            throw CloneClawManagerError.ownershipFixFailed(path, "owner=\(owner ?? "unknown"), expected=\(username)")
        }
    }

    private func rollbackCloneUser(username: String) {
        let home = "/Users/\(username)"
        try? FileManager.default.removeItem(atPath: "\(home)/.openclaw")
        try? FileManager.default.removeItem(atPath: "\(home)/.npm-global")
        UserManager.prepareDeleteUser(username: username)
        _ = try? dscl(["-delete", "/Users/\(username)"])
        try? FileManager.default.removeItem(atPath: home)
        UserManager.cleanupDeletedUser(username: username)
    }

    private func generatedClonePassword() -> String {
        "clawd-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
    }

    private func resolveCloneGatewayURL(username: String, uid: Int) -> String {
        let port = GatewayManager.readConfiguredPort(username: username) ?? GatewayManager.port(for: uid)
        let base = "http://127.0.0.1:\(port)/"
        if let token = ConfigWriter.getRawConfigValue(username: username, key: "gateway.auth.token"),
           !token.isEmpty {
            return "\(base)#token=\(token)"
        }
        return base
    }
}
