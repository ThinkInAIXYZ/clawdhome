// ClawdHomeHelper/HelperImpl+Diagnostics.swift
// 体检 + 统一诊断

import Foundation

extension ClawdHomeHelperImpl {

    // MARK: - 体检

    func runHealthCheck(username: String, fix: Bool,
                        withReply reply: @escaping (Bool, String) -> Void) {
        let home = "/Users/\(username)"
        var findings: [HealthFinding] = []

        // --- 环境隔离检查（FileManager.attributesOfItem，无子进程）---

        // 检查 1：家目录权限（应为 700，不应 group/world 可访问）
        // macOS 所有用户都在 staff 组（gid=20），750 等同于对所有用户开放，必须设为 700
        if let attrs = try? FileManager.default.attributesOfItem(atPath: home),
           let perms = attrs[.posixPermissions] as? Int {
            let groupOrOthersAccess = (perms & 0o077) != 0
            if groupOrOthersAccess {
                var fixed: Bool? = nil
                var fixError: String? = nil
                if fix {
                    do { try run("/bin/chmod", args: ["700", home]); fixed = true }
                    catch { fixed = false; fixError = error.localizedDescription }
                }
                findings.append(HealthFinding(
                    id: "home-perms", source: "isolation", severity: "critical",
                    title: "家目录未隔离",
                    detail: "当前权限 \(String(format: "%o", perms))，所有用户均在 staff 组，必须设为 700 才能阻止其他用户浏览文件",
                    fixable: true, fixed: fixed, fixError: fixError))
            }
        }

        // 检查 2：.openclaw 目录权限（含 API Key 等敏感数据，不应 group/world 可访问）
        let openclawDir = "\(home)/.openclaw"
        if FileManager.default.fileExists(atPath: openclawDir),
           let attrs = try? FileManager.default.attributesOfItem(atPath: openclawDir),
           let perms = attrs[.posixPermissions] as? Int {
            let groupOrOthersAccess = (perms & 0o077) != 0
            if groupOrOthersAccess {
                var fixed: Bool? = nil
                var fixError: String? = nil
                if fix {
                    do { try run("/bin/chmod", args: ["-R", "go-rwx", openclawDir]); fixed = true }
                    catch { fixed = false; fixError = error.localizedDescription }
                }
                findings.append(HealthFinding(
                    id: "openclaw-perms", source: "isolation", severity: "critical",
                    title: ".openclaw 目录权限过宽",
                    detail: "当前权限 \(String(format: "%o", perms))，API Key 等敏感数据对其他用户可见",
                    fixable: true, fixed: fixed, fixError: fixError))
            }
        }

        // 检查 3：npm-global 目录权限（包含可执行文件，不应 world-writable）
        let npmGlobal = InstallManager.npmGlobalDir(for: username)
        if FileManager.default.fileExists(atPath: npmGlobal),
           let attrs = try? FileManager.default.attributesOfItem(atPath: npmGlobal),
           let perms = attrs[.posixPermissions] as? Int {
            let worldWritable = (perms & 0o002) != 0
            if worldWritable {
                var fixed: Bool? = nil
                var fixError: String? = nil
                if fix {
                    do { try run("/bin/chmod", args: ["o-w", npmGlobal]); fixed = true }
                    catch { fixed = false; fixError = error.localizedDescription }
                }
                findings.append(HealthFinding(
                    id: "npm-global-writable", source: "isolation", severity: "critical",
                    title: "npm 全局目录可被任意用户写入",
                    detail: "当前权限 \(String(format: "%o", perms))，其他用户可替换可执行文件（潜在供应链风险）",
                    fixable: true, fixed: fixed, fixError: fixError))
            }
        }

        // 检查 4：家目录归属（Helper 以 root 运行，可能遗漏 chown）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: home),
           let owner = attrs[.ownerAccountName] as? String, owner != username {
            var fixed: Bool? = nil
            var fixError: String? = nil
            if fix {
                do { try run("/usr/sbin/chown", args: [username, home]); fixed = true }
                catch { fixed = false; fixError = error.localizedDescription }
            }
            findings.append(HealthFinding(
                id: "home-owner", source: "isolation", severity: "critical",
                title: "家目录归属错误",
                detail: "家目录当前归属 \(owner)，应归属 \(username)，用户无法写入自己的家目录",
                fixable: true, fixed: fixed, fixError: fixError))
        }

        // 检查 5：.openclaw 目录归属（openclaw CLI 以用户身份运行，需要写权限）
        if FileManager.default.fileExists(atPath: openclawDir),
           let attrs = try? FileManager.default.attributesOfItem(atPath: openclawDir),
           let owner = attrs[.ownerAccountName] as? String, owner != username {
            var fixed: Bool? = nil
            var fixError: String? = nil
            if fix {
                do { try run("/usr/sbin/chown", args: ["-R", username, openclawDir]); fixed = true }
                catch { fixed = false; fixError = error.localizedDescription }
            }
            findings.append(HealthFinding(
                id: "openclaw-owner", source: "isolation", severity: "critical",
                title: ".openclaw 目录归属错误",
                detail: ".openclaw 当前归属 \(owner)，应归属 \(username)，导致 openclaw CLI 无法读写配置",
                fixable: true, fixed: fixed, fixError: fixError))
        }

        // 检查 6：openclaw.json 配置文件归属（用户需要能写入，否则 config set 静默失败）
        let configFile = "\(openclawDir)/openclaw.json"
        if FileManager.default.fileExists(atPath: configFile),
           let attrs = try? FileManager.default.attributesOfItem(atPath: configFile),
           let owner = attrs[.ownerAccountName] as? String, owner != username {
            var fixed: Bool? = nil
            var fixError: String? = nil
            if fix {
                do { try run("/usr/sbin/chown", args: [username, configFile]); fixed = true }
                catch { fixed = false; fixError = error.localizedDescription }
            }
            findings.append(HealthFinding(
                id: "config-owner", source: "isolation", severity: "critical",
                title: "配置文件归属错误",
                detail: "openclaw.json 当前归属 \(owner)，应归属 \(username)，导致 API Key 等配置无法保存",
                fixable: true, fixed: fixed, fixError: fixError))
        }

        // 检查 7：npm-global 目录归属（包含 openclaw 可执行文件，需要用户可执行）
        if FileManager.default.fileExists(atPath: npmGlobal),
           let attrs = try? FileManager.default.attributesOfItem(atPath: npmGlobal),
           let owner = attrs[.ownerAccountName] as? String, owner != username {
            var fixed: Bool? = nil
            var fixError: String? = nil
            if fix {
                do { try run("/usr/sbin/chown", args: ["-R", username, npmGlobal]); fixed = true }
                catch { fixed = false; fixError = error.localizedDescription }
            }
            findings.append(HealthFinding(
                id: "npm-global-owner", source: "isolation", severity: "critical",
                title: "npm 全局目录归属错误",
                detail: "~/.npm-global 当前归属 \(owner)，应归属 \(username)，openclaw 命令无法执行",
                fixable: true, fixed: fixed, fixError: fixError))
        }

        // --- 应用安全审计（openclaw security audit --json）---
        var auditSkipped = false
        var auditError: String? = nil

        guard let openclawPath = try? ConfigWriter.findOpenclawBinary(for: username) else {
            // openclaw 未安装，跳过审计
            auditSkipped = true
            let result = HealthCheckResult(username: username,
                checkedAt: Date().timeIntervalSince1970,
                findings: findings, auditSkipped: true, auditError: nil)
            encodeAndReply(result, reply)
            return
        }

        let nodePath = ConfigWriter.buildNodePath(username: username)
        let auditEnv = ["-n", "-u", username, "-H", "/usr/bin/env", "PATH=\(nodePath)", openclawPath, "security", "audit", "--json"]

        if let output = try? run("/usr/bin/sudo", args: auditEnv) {
            let initialFindings = parseAuditOutput(output)

            if fix && !initialFindings.isEmpty {
                // 运行 openclaw doctor --repair 修复应用层问题
                _ = try? run("/usr/bin/sudo", args: [
                    "-n", "-u", username, "-H", "/usr/bin/env", "PATH=\(nodePath)", openclawPath, "doctor", "--repair"
                ])
                // 修复后重新审计，对比前后 id 差异
                if let postOutput = try? run("/usr/bin/sudo", args: auditEnv) {
                    let postFindings = parseAuditOutput(postOutput)
                    let postIDs      = Set(postFindings.map { $0.id })
                    let initialIDs   = Set(initialFindings.map { $0.id })
                    // 原有发现：消失的 = 已修复，仍在的 = 未修复
                    for f in initialFindings {
                        findings.append(HealthFinding(
                            id: f.id, source: f.source, severity: f.severity,
                            title: f.title, detail: f.detail,
                            fixable: true, fixed: !postIDs.contains(f.id), fixError: nil))
                    }
                    // 修复后新增的发现（防御性处理）
                    for f in postFindings where !initialIDs.contains(f.id) {
                        findings.append(f)
                    }
                } else {
                    // 重新审计失败，保留原始发现并标记修复状态未知
                    for f in initialFindings {
                        findings.append(HealthFinding(
                            id: f.id, source: f.source, severity: f.severity,
                            title: f.title, detail: f.detail,
                            fixable: true, fixed: false, fixError: "修复后重新检查失败"))
                    }
                }
            } else {
                findings += initialFindings
            }
        } else {
            auditError = "安全审计执行失败（openclaw security audit --json）"
        }

        let result = HealthCheckResult(username: username,
            checkedAt: Date().timeIntervalSince1970,
            findings: findings, auditSkipped: auditSkipped, auditError: auditError)
        encodeAndReply(result, reply)
    }

    /// 解析 `openclaw security audit --json` 输出
    /// 兼容 {"findings":[...]} / {"issues":[...]} / 直接数组 [...] 三种格式
    func parseAuditOutput(_ output: String) -> [HealthFinding] {
        guard let data = output.data(using: .utf8) else { return [] }
        var rawList: [[String: Any]] = []
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rawList = (obj["findings"] as? [[String: Any]])
                ?? (obj["issues"] as? [[String: Any]]) ?? []
        } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rawList = arr
        }
        return rawList.enumerated().map { i, raw in
            let id       = (raw["id"] as? String) ?? "\(i)"
            let severity = (raw["severity"] as? String) ?? "info"
            let title    = (raw["title"] as? String) ?? (raw["name"] as? String) ?? "安全建议"
            let detail   = (raw["detail"] as? String)
                ?? (raw["description"] as? String)
                ?? (raw["message"] as? String) ?? ""
            return HealthFinding(id: "audit-\(id)", source: "audit",
                severity: severity, title: title, detail: detail,
                fixable: true, fixed: nil, fixError: nil)
        }
    }

    private func encodeAndReply(_ result: HealthCheckResult,
                                 _ reply: (Bool, String) -> Void) {
        if let data = try? JSONEncoder().encode(result),
           let json = String(data: data, encoding: .utf8) {
            reply(true, json)
        } else {
            reply(false, "{}")
        }
    }

    // MARK: - 统一诊断

    func runDiagnostics(username: String, fix: Bool,
                        withReply reply: @escaping (Bool, String) -> Void) {
        helperLog("统一诊断 @\(username) fix=\(fix)")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let items = self.collectDiagnostics(username: username, fix: fix)
            let result = DiagnosticsResult(username: username,
                checkedAt: Date().timeIntervalSince1970, items: items)
            if let data = try? JSONEncoder().encode(result),
               let json = String(data: data, encoding: .utf8) {
                reply(true, json)
            } else {
                reply(false, "{}")
            }
        }
    }

    func runDiagnosticGroup(username: String, groupName: String, fix: Bool,
                            withReply reply: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let group = DiagnosticGroup(rawValue: groupName) else {
                reply(false, "[]")
                return
            }
            let items: [DiagnosticItem]
            switch group {
            case .environment:  items = self.diagEnvironment(username: username, fix: fix)
            case .permissions:  items = self.diagPermissions(username: username, fix: fix)
            case .config:       items = self.diagConfig(username: username, fix: fix)
            case .security:     items = self.diagSecurity(username: username, fix: fix)
            case .gateway:      items = self.diagGateway(username: username)
            case .network:      items = self.diagNetwork(username: username)
            }
            if let data = try? JSONEncoder().encode(items),
               let json = String(data: data, encoding: .utf8) {
                reply(true, json)
            } else {
                reply(false, "[]")
            }
        }
    }

    private func collectDiagnostics(username: String, fix: Bool) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        items += diagEnvironment(username: username, fix: fix)
        items += diagPermissions(username: username, fix: fix)
        items += diagConfig(username: username, fix: fix)
        items += diagSecurity(username: username, fix: fix)
        items += diagGateway(username: username)
        items += diagNetwork(username: username)
        return items
    }

    // MARK: 诊断 - 环境检测

    private func diagEnvironment(username: String, fix: Bool) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        let nodeInstalled = NodeDownloader.isInstalled(for: username)
        if nodeInstalled {
            let nodePath = "/Users/\(username)/.brew/bin/node"
            let versionRaw: String = (try? run(nodePath, args: ["--version"])) ?? "未知"
            let version = versionRaw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            items.append(DiagnosticItem(
                id: "env-node", group: .environment, severity: "ok",
                title: "Node.js 已安装",
                detail: version,
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        } else {
            items.append(DiagnosticItem(
                id: "env-node", group: .environment, severity: "critical",
                title: "Node.js 未安装",
                detail: "Gateway 运行需要 Node.js 环境",
                fixable: true, fixed: nil, fixError: nil, latencyMs: nil))
        }

        if let _ = try? ConfigWriter.findOpenclawBinary(for: username) {
            let version = InstallManager.installedVersion(username: username) ?? "未知"
            items.append(DiagnosticItem(
                id: "env-openclaw", group: .environment, severity: "ok",
                title: "OpenClaw 已安装",
                detail: "v\(version)",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        } else {
            items.append(DiagnosticItem(
                id: "env-openclaw", group: .environment, severity: "critical",
                title: "OpenClaw 未安装",
                detail: "请先完成初始化向导安装 OpenClaw",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        }

        let npmGlobal = InstallManager.npmGlobalDir(for: username)
        if FileManager.default.fileExists(atPath: npmGlobal) {
            items.append(DiagnosticItem(
                id: "env-npm-global", group: .environment, severity: "ok",
                title: "npm 全局目录正常",
                detail: npmGlobal,
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        } else {
            items.append(DiagnosticItem(
                id: "env-npm-global", group: .environment, severity: "warn",
                title: "npm 全局目录不存在",
                detail: "\(npmGlobal) 未创建",
                fixable: true, fixed: nil, fixError: nil, latencyMs: nil))
        }

        return items
    }

    // MARK: 诊断 - 权限检测

    private func diagPermissions(username: String, fix: Bool) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        let home = "/Users/\(username)"
        let openclawDir = "\(home)/.openclaw"
        let npmGlobal = InstallManager.npmGlobalDir(for: username)
        let configFile = "\(openclawDir)/openclaw.json"

        func checkPerms(id: String, path: String, title: String, detail: String,
                        check: (Int) -> Bool, fixArgs: [String]) {
            guard FileManager.default.fileExists(atPath: path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let perms = attrs[.posixPermissions] as? Int else { return }
            if check(perms) {
                var fixed: Bool? = nil
                var fixError: String? = nil
                if fix {
                    do { try run("/bin/chmod", args: fixArgs); fixed = true }
                    catch { fixed = false; fixError = error.localizedDescription }
                }
                items.append(DiagnosticItem(
                    id: id, group: .permissions, severity: "critical",
                    title: title,
                    detail: "\(detail)（当前 \(String(format: "%o", perms))）",
                    fixable: true, fixed: fixed, fixError: fixError, latencyMs: nil))
            }
        }

        func checkOwner(id: String, path: String, title: String, recursive: Bool) {
            guard FileManager.default.fileExists(atPath: path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let owner = attrs[.ownerAccountName] as? String, owner != username else { return }
            var fixed: Bool? = nil
            var fixError: String? = nil
            if fix {
                let args = recursive ? ["-R", username, path] : [username, path]
                do { try run("/usr/sbin/chown", args: args); fixed = true }
                catch { fixed = false; fixError = error.localizedDescription }
            }
            items.append(DiagnosticItem(
                id: id, group: .permissions, severity: "critical",
                title: title,
                detail: "当前归属 \(owner)，应归属 \(username)",
                fixable: true, fixed: fixed, fixError: fixError, latencyMs: nil))
        }

        checkPerms(id: "perm-home", path: home,
                   title: "家目录未隔离", detail: "应设为 700",
                   check: { ($0 & 0o077) != 0 }, fixArgs: ["700", home])
        checkPerms(id: "perm-openclaw-dir", path: openclawDir,
                   title: ".openclaw 目录权限过宽", detail: "API Key 等敏感数据对其他用户可见",
                   check: { ($0 & 0o077) != 0 }, fixArgs: ["-R", "go-rwx", openclawDir])
        checkPerms(id: "perm-npm-writable", path: npmGlobal,
                   title: "npm 全局目录可被任意用户写入", detail: "潜在供应链风险",
                   check: { ($0 & 0o002) != 0 }, fixArgs: ["o-w", npmGlobal])
        checkOwner(id: "perm-home-owner", path: home, title: "家目录归属错误", recursive: false)
        checkOwner(id: "perm-openclaw-owner", path: openclawDir, title: ".openclaw 目录归属错误", recursive: true)
        checkOwner(id: "perm-config-owner", path: configFile, title: "配置文件归属错误", recursive: false)
        checkOwner(id: "perm-npm-owner", path: npmGlobal, title: "npm 全局目录归属错误", recursive: true)

        if items.isEmpty {
            items.append(DiagnosticItem(
                id: "perm-ok", group: .permissions, severity: "ok",
                title: "权限配置正常",
                detail: "无隔离风险",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        }

        return items
    }

    // MARK: 诊断 - 配置校验（直接读取 openclaw.json 验证，不依赖 CLI）

    private func diagConfig(username: String, fix: Bool) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        let configPath = "/Users/\(username)/.openclaw/openclaw.json"

        // 1. 检查文件是否存在
        guard FileManager.default.fileExists(atPath: configPath) else {
            items.append(DiagnosticItem(
                id: "config-skip", group: .config, severity: "info",
                title: "跳过配置校验",
                detail: "openclaw.json 不存在",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
            return items
        }

        // 2. 读取并解析 JSON
        guard let data = FileManager.default.contents(atPath: configPath) else {
            items.append(DiagnosticItem(
                id: "config-read-fail", group: .config, severity: "critical",
                title: "配置文件无法读取",
                detail: configPath,
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
            return items
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            items.append(DiagnosticItem(
                id: "config-json-invalid", group: .config, severity: "critical",
                title: "openclaw.json 格式错误",
                detail: "文件不是合法 JSON",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
            return items
        }

        // 3. 校验关键字段
        var problems: [DiagnosticItem] = []

        // gateway 配置
        if let gw = root["gateway"] as? [String: Any] {
            if gw["port"] == nil {
                problems.append(DiagnosticItem(
                    id: "config-no-gw-port", group: .config, severity: "warn",
                    title: "缺少 gateway.port",
                    detail: "Gateway 端口未配置",
                    fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
            }
            if gw["auth"] == nil {
                problems.append(DiagnosticItem(
                    id: "config-no-gw-auth", group: .config, severity: "warn",
                    title: "缺少 gateway.auth",
                    detail: "Gateway 认证未配置",
                    fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
            }
        } else {
            problems.append(DiagnosticItem(
                id: "config-no-gateway", group: .config, severity: "warn",
                title: "缺少 gateway 配置段",
                detail: "Gateway 未配置，可能无法启动",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        }

        // models 配置
        if root["models"] == nil {
            problems.append(DiagnosticItem(
                id: "config-no-models", group: .config, severity: "warn",
                title: "缺少 models 配置段",
                detail: "未配置任何模型提供商",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        }

        // auth 配置
        if root["auth"] == nil {
            problems.append(DiagnosticItem(
                id: "config-no-auth", group: .config, severity: "info",
                title: "缺少 auth 配置段",
                detail: "未配置认证 profile",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        }

        if problems.isEmpty {
            items.append(DiagnosticItem(
                id: "config-ok", group: .config, severity: "ok",
                title: "配置校验通过",
                detail: "openclaw.json 合法，关键字段完整",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        } else {
            items += problems
        }

        return items
    }

    // MARK: 诊断 - 安全审计

    private func diagSecurity(username: String, fix: Bool) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        guard let openclawPath = try? ConfigWriter.findOpenclawBinary(for: username) else {
            items.append(DiagnosticItem(
                id: "security-skip", group: .security, severity: "info",
                title: "跳过安全审计",
                detail: "OpenClaw 未安装",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
            return items
        }

        let nodePath = ConfigWriter.buildNodePath(username: username)
        let auditArgs = ["-n", "-u", username, "-H", "/usr/bin/env", "PATH=\(nodePath)",
                         openclawPath, "security", "audit", "--json"]

        do {
            let output = try run("/usr/bin/sudo", args: auditArgs)
            let findings = parseAuditOutput(output)
            if findings.isEmpty {
                items.append(DiagnosticItem(
                    id: "security-ok", group: .security, severity: "ok",
                    title: "无安全审计问题",
                    detail: "",
                    fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
            } else if fix {
                let fixArgs = ["-n", "-u", username, "-H", "/usr/bin/env", "PATH=\(nodePath)",
                               openclawPath, "doctor", "--repair"]
                _ = try? run("/usr/bin/sudo", args: fixArgs)
                if let postOutput = try? run("/usr/bin/sudo", args: auditArgs) {
                    let postFindings = parseAuditOutput(postOutput)
                    let postIDs = Set(postFindings.map { $0.id })
                    for f in findings {
                        items.append(DiagnosticItem(
                            id: f.id, group: .security, severity: f.severity,
                            title: f.title, detail: f.detail,
                            fixable: true, fixed: !postIDs.contains(f.id),
                            fixError: nil, latencyMs: nil))
                    }
                } else {
                    for f in findings {
                        items.append(DiagnosticItem(
                            id: f.id, group: .security, severity: f.severity,
                            title: f.title, detail: f.detail,
                            fixable: true, fixed: false,
                            fixError: "修复后重新检查失败", latencyMs: nil))
                    }
                }
            } else {
                for f in findings {
                    items.append(DiagnosticItem(
                        id: f.id, group: .security, severity: f.severity,
                        title: f.title, detail: f.detail,
                        fixable: true, fixed: nil, fixError: nil, latencyMs: nil))
                }
            }
        } catch {
            let errorDetail: String
            if case ShellError.nonZeroExit(_, _, let stderr) = error, !stderr.isEmpty {
                errorDetail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                errorDetail = error.localizedDescription
            }
            items.append(DiagnosticItem(
                id: "security-fail", group: .security, severity: "warn",
                title: "安全审计执行失败",
                detail: errorDetail,
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        }

        return items
    }

    // MARK: 诊断 - Gateway 状态

    private func diagGateway(username: String) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        guard let uid = try? UserManager.uid(for: username) else {
            items.append(DiagnosticItem(
                id: "gw-uid", group: .gateway, severity: "warn",
                title: "无法获取用户 UID",
                detail: "用户 \(username) 可能不存在",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
            return items
        }

        let (running, pid) = GatewayManager.status(username: username, uid: uid)
        if running {
            items.append(DiagnosticItem(
                id: "gw-running", group: .gateway, severity: "ok",
                title: "Gateway 正在运行",
                detail: "PID \(pid)",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        } else {
            items.append(DiagnosticItem(
                id: "gw-stopped", group: .gateway, severity: "info",
                title: "Gateway 未运行",
                detail: "",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        }

        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let gateway = json["gateway"] as? [String: Any],
           let port = gateway["port"] as? Int {
            items.append(DiagnosticItem(
                id: "gw-port", group: .gateway, severity: "ok",
                title: "配置端口",
                detail: "\(port)",
                fixable: false, fixed: nil, fixError: nil, latencyMs: nil))
        }

        return items
    }

    // MARK: 诊断 - 网络连通

    private func diagNetwork(username: String) -> [DiagnosticItem] {
        let sites = [
            ("baidu.com",  "https://baidu.com"),
            ("google.com", "https://google.com"),
            ("github.com", "https://github.com"),
            ("openai.com", "https://openai.com"),
        ]

        let group = DispatchGroup()
        let lock = NSLock()
        var results: [(String, String, Int?)] = []

        for (name, urlStr) in sites {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let latency = self.measureHTTPLatency(urlStr: urlStr)
                lock.lock()
                results.append((name, urlStr, latency))
                lock.unlock()
                group.leave()
            }
        }

        group.wait()

        let orderedNames = sites.map { $0.0 }
        results.sort { orderedNames.firstIndex(of: $0.0)! < orderedNames.firstIndex(of: $1.0)! }

        return results.map { (name, _, latency) in
            if let ms = latency {
                return DiagnosticItem(
                    id: "net-\(name)", group: .network, severity: "ok",
                    title: name,
                    detail: "\(ms) ms",
                    fixable: false, fixed: nil, fixError: nil, latencyMs: ms)
            } else {
                return DiagnosticItem(
                    id: "net-\(name)", group: .network, severity: "warn",
                    title: name,
                    detail: "不可达",
                    fixable: false, fixed: nil, fixError: nil, latencyMs: nil)
            }
        }
    }

    private func measureHTTPLatency(urlStr: String) -> Int? {
        guard let url = URL(string: urlStr) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6

        let semaphore = DispatchSemaphore(value: 0)
        var latencyMs: Int?

        let start = DispatchTime.now()
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse, http.statusCode > 0 {
                let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                latencyMs = Int(elapsed / 1_000_000)
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 8)

        return latencyMs
    }
}
