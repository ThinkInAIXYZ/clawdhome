// ClawdHomeHelper/HelperImpl+Hermes.swift
// Hermes Agent 引擎的 XPC 方法实现（安装 + 生命周期 + 状态）
//
// 与 HelperImpl+Install / HelperImpl+UserGateway（openclaw 侧）对称。
// 二者公用同一 macOS 用户账号：一个虾可以同时装 openclaw 和 hermes，
// 由上层（App/CLI）决定当前启用哪一个引擎。

import Foundation

extension ClawdHomeHelperImpl {

    // MARK: - 安装

    func installHermes(username: String, version: String?,
                       withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("安装 hermes @\(username) v\(version ?? "latest")")
        let logURL = hermesInitLogURL(username: username)
        do {
            try HermesInstaller.install(username: username, version: version, logURL: logURL)
            reply(true, nil)
        } catch {
            helperLog("安装 hermes 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func cancelHermesInstall(username: String, withReply reply: @escaping (Bool) -> Void) {
        let logPath = hermesInitLogURL(username: username).path
        terminateManagedProcess(logPath: logPath)
        helperLog("Hermes 安装已取消 @\(username)")
        reply(true)
    }

    func getHermesVersion(username: String, withReply reply: @escaping (String) -> Void) {
        reply(HermesInstaller.installedVersion(username: username) ?? "")
    }

    // MARK: - 生命周期（profile-aware）

    func startHermesGateway(username: String, profileID: String,
                            withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("Hermes 启动 profile=\(profileID) @\(username)")
        do {
            let uid = try UserManager.uid(for: username)
            try HermesGatewayManager.startGateway(username: username, profileID: profileID, uid: uid)
            reply(true, nil)
        } catch {
            helperLog("Hermes 启动失败 profile=\(profileID) @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    /// 向后兼容：转发到 profileID="main"
    func startHermesGateway(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        startHermesGateway(username: username, profileID: "main", withReply: reply)
    }

    func stopHermesGateway(username: String, profileID: String,
                           withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("Hermes 停止 profile=\(profileID) @\(username)")
        do {
            let uid = try UserManager.uid(for: username)
            try HermesGatewayManager.stopGateway(username: username, profileID: profileID, uid: uid)
            reply(true, nil)
        } catch {
            helperLog("Hermes 停止失败 profile=\(profileID) @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    /// 向后兼容：转发到 profileID="main"
    func stopHermesGateway(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        stopHermesGateway(username: username, profileID: "main", withReply: reply)
    }

    func getHermesGatewayStatus(username: String, profileID: String,
                                withReply reply: @escaping (Bool, Int32) -> Void) {
        let (running, pid) = HermesGatewayManager.status(username: username, profileID: profileID)
        reply(running, pid)
    }

    /// 向后兼容：转发到 profileID="main"
    func getHermesGatewayStatus(username: String, withReply reply: @escaping (Bool, Int32) -> Void) {
        getHermesGatewayStatus(username: username, profileID: "main", withReply: reply)
    }

    func uninstallHermesGateway(username: String, profileID: String,
                                withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("Hermes 卸载 gateway profile=\(profileID) @\(username)")
        do {
            try HermesGatewayManager.uninstallGateway(username: username, profileID: profileID)
            reply(true, nil)
        } catch {
            helperLog("Hermes 卸载 gateway 失败 profile=\(profileID) @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - 初始化配置（profile-aware，PR-3 完整实现 profileID 路径分发）

    func applyHermesInitConfig(
        username: String,
        profileID: String,
        payloadJSON: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("Hermes apply init config profile=\(profileID) @\(username) bytes=\(payloadJSON.utf8.count)")
        do {
            try HermesConfigWriter.apply(username: username, profileID: profileID, payloadJSON: payloadJSON)
            reply(true, nil)
        } catch {
            helperLog("Hermes apply init config 失败 profile=\(profileID) @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    /// 向后兼容：转发到 profileID="main"
    func applyHermesInitConfig(
        username: String,
        payloadJSON: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        applyHermesInitConfig(username: username, profileID: "main", payloadJSON: payloadJSON, withReply: reply)
    }

    func getHermesInitSummary(username: String, profileID: String,
                              withReply reply: @escaping (String) -> Void) {
        helperLog("Hermes get init summary profile=\(profileID) @\(username)")
        reply(HermesConfigWriter.initSummaryJSON(username: username, profileID: profileID))
    }

    /// 向后兼容：转发到 profileID="main"
    func getHermesInitSummary(username: String, withReply reply: @escaping (String) -> Void) {
        getHermesInitSummary(username: username, profileID: "main", withReply: reply)
    }

    func validateHermesInitConfig(
        username: String,
        profileID: String,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        helperLog("Hermes validate init config profile=\(profileID) @\(username)")
        reply(true, HermesConfigWriter.validateJSON(username: username, profileID: profileID))
    }

    /// 向后兼容：转发到 profileID="main"
    func validateHermesInitConfig(
        username: String,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        validateHermesInitConfig(username: username, profileID: "main", withReply: reply)
    }

    // MARK: - Hermes profiles

    func listHermesProfiles(
        username: String,
        withReply reply: @escaping (String?, String?) -> Void
    ) {
        helperLog("Hermes list profiles @\(username)")
        do {
            let json = try HermesProfileManager.listProfiles(username: username)
            reply(json, nil)
        } catch {
            helperLog("Hermes list profiles 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(nil, error.localizedDescription)
        }
    }

    func createHermesProfile(
        username: String,
        configJSON: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("Hermes create profile @\(username)")
        do {
            try HermesProfileManager.createProfile(username: username, configJSON: configJSON)
            reply(true, nil)
        } catch {
            helperLog("Hermes create profile 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func getHermesActiveProfile(
        username: String,
        withReply reply: @escaping (String) -> Void
    ) {
        helperLog("Hermes get active profile @\(username)")
        reply(HermesProfileManager.activeProfileID(username: username))
    }

    func setHermesActiveProfile(
        username: String,
        profileID: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("Hermes set active profile @\(username): \(profileID)")
        do {
            try HermesProfileManager.setActiveProfile(username: username, profileID: profileID)
            reply(true, nil)
        } catch {
            helperLog("Hermes set active profile 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func removeHermesProfile(
        username: String,
        profileID: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("Hermes remove profile @\(username): \(profileID)")
        do {
            try HermesProfileManager.removeProfile(username: username, profileID: profileID)
            reply(true, nil)
        } catch {
            helperLog("Hermes remove profile 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - Hermes IM 绑定（PR-3）

    func applyHermesIMBinding(
        username: String,
        profileID: String,
        payloadJSON: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("Hermes apply IM binding profile=\(profileID) @\(username)")

        // 解析 payload
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platform = obj["platform"] as? String,
              let envAny = obj["env"] as? [String: Any] else {
            reply(false, "im_binding_invalid_payload")
            return
        }
        let env = envAny.compactMapValues { $0 as? String }

        // 查找平台定义
        guard let platformDef = HermesIMPlatforms.find(key: platform) else {
            reply(false, "im_unknown_platform:\(platform)")
            return
        }

        // 校验必填 key
        for key in platformDef.requiredEnvKeys {
            let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else {
                helperLog("Hermes IM binding 必填 key 缺失：\(key) platform=\(platform) @\(username)", level: .error)
                reply(false, "im_token_missing:\(key)")
                return
            }
        }

        // 写入 .env
        do {
            try HermesConfigWriter.writeIMBindingEnv(
                username: username,
                profileID: profileID,
                platform: platform,
                env: env
            )
            helperLog("Hermes IM binding 写入成功 platform=\(platform) profile=\(profileID) @\(username)")
            reply(true, nil)
        } catch {
            helperLog("Hermes IM binding 写入失败 platform=\(platform) profile=\(profileID) @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func runHermesDoctor(
        username: String,
        profileID: String,
        withReply reply: @escaping (String) -> Void
    ) {
        helperLog("Hermes doctor profile=\(profileID) @\(username)")

        // 检查 hermes 是否安装
        let hermesBin = HermesInstaller.hermesExecutable(for: username)
        guard FileManager.default.isExecutableFile(atPath: hermesBin) else {
            helperLog("Hermes doctor 失败：hermes 未安装 @\(username)", level: .error)
            reply(#"{"ok":false,"platforms":{},"raw":"hermes_not_installed"}"#)
            return
        }

        // 构建命令参数
        let profileArgs: [String]
        if profileID == "main" {
            profileArgs = []
        } else {
            profileArgs = ["--profile", profileID]
        }

        // 以 shrimp 用户身份执行 hermes doctor --json（超时 30s）
        let result = runHermesDoctorCommand(
            username: username,
            hermesBin: hermesBin,
            profileArgs: profileArgs,
            profileID: profileID
        )
        reply(result)
    }

    /// 内部辅助：执行 hermes doctor，优先尝试 --json，若失败则回退正则解析
    private func runHermesDoctorCommand(
        username: String,
        hermesBin: String,
        profileArgs: [String],
        profileID: String
    ) -> String {
        // 尝试 --json 模式
        let jsonArgs = profileArgs + ["doctor", "--json"]
        if let (ok, platforms, raw) = execHermesDoctorAs(
            username: username,
            hermesBin: hermesBin,
            args: jsonArgs,
            tryParseJSON: true
        ) {
            return buildDoctorJSON(ok: ok, platforms: platforms, raw: raw)
        }

        // 回退：无 --json flag，正则解析
        helperLog("Hermes doctor --json 不可用，回退正则解析 profile=\(profileID) @\(username)")
        let plainArgs = profileArgs + ["doctor"]
        if let (ok, platforms, raw) = execHermesDoctorAs(
            username: username,
            hermesBin: hermesBin,
            args: plainArgs,
            tryParseJSON: false
        ) {
            return buildDoctorJSON(ok: ok, platforms: platforms, raw: raw)
        }

        return #"{"ok":false,"platforms":{},"raw":"doctor_exec_failed"}"#
    }

    /// 以 shrimp 用户身份执行 hermes doctor，返回 (ok, platforms, raw) 或 nil
    private func execHermesDoctorAs(
        username: String,
        hermesBin: String,
        args: [String],
        tryParseJSON: Bool
    ) -> (Bool, [String: String], String)? {
        let command = ([hermesBin] + args).joined(separator: " ")
        let suCommand = "\(command)"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/su")
        proc.arguments = ["-l", username, "-c", suCommand]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            helperLog("Hermes doctor su exec 失败 @\(username): \(error.localizedDescription)", level: .error)
            return nil
        }

        // 超时 30s
        let deadline = DispatchTime.now() + .seconds(30)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            proc.waitUntilExit()
            group.leave()
        }
        let waitResult = group.wait(timeout: deadline)
        if waitResult == .timedOut {
            proc.terminate()
            helperLog("Hermes doctor 超时（30s） @\(username)", level: .error)
            return nil
        }

        let rawOut = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let rawErr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = (rawOut + rawErr).trimmingCharacters(in: .whitespacesAndNewlines)
        // 截断 4KB
        let raw = String(combined.prefix(4096))

        if tryParseJSON {
            // 尝试解析 JSON 输出
            if let parsed = parseDoctorJSON(raw) {
                return parsed
            }
            // --json 输出不可解析（可能不支持该 flag），返回 nil 让调用方回退
            return nil
        } else {
            // 正则解析普通文本输出
            return parseDoctorPlainText(raw)
        }
    }

    /// 解析 hermes doctor --json 输出
    private func parseDoctorJSON(_ raw: String) -> (Bool, [String: String], String)? {
        // 找到 JSON 部分（hermes 可能有前置日志行）
        let lines = raw.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let ok = obj["ok"] as? Bool ?? false
            var platforms: [String: String] = [:]
            if let plats = obj["platforms"] as? [String: String] {
                platforms = plats
            } else if let plats = obj["platforms"] as? [String: Any] {
                for (k, v) in plats {
                    if let sv = v as? String {
                        platforms[k] = sv
                    } else if let bv = v as? Bool {
                        platforms[k] = bv ? "ready" : "unknown_error"
                    }
                }
            }
            return (ok, platforms, raw)
        }
        return nil
    }

    /// 用正则/文本匹配解析 hermes doctor 普通输出
    private func parseDoctorPlainText(_ raw: String) -> (Bool, [String: String], String) {
        var platforms: [String: String] = [:]
        let lower = raw.lowercased()

        // 各平台关键词 → key 映射
        let platformKeywords: [(keyword: String, key: String)] = [
            ("telegram", "telegram"),
            ("slack", "slack"),
            ("discord", "discord"),
            ("feishu", "feishu"),
            ("wecom", "wecom"),
            ("dingtalk", "dingtalk"),
            ("email", "email"),
            ("signal", "signal"),
            ("matrix", "matrix"),
            ("mattermost", "mattermost"),
            ("whatsapp", "whatsapp"),
            ("weixin", "weixin"),
        ]

        for (keyword, key) in platformKeywords {
            // 在含有平台关键词的行里查找状态词
            let relevantLines = raw.components(separatedBy: "\n").filter {
                $0.lowercased().contains(keyword)
            }
            var status = "unknown_error"
            for line in relevantLines {
                let l = line.lowercased()
                if l.contains("ok") || l.contains("ready") || l.contains("✓") || l.contains("configured") {
                    status = "ready"
                    break
                } else if l.contains("missing") || l.contains("not set") || l.contains("no token") || l.contains("✗") {
                    status = "missing_token"
                    break
                } else if l.contains("error") || l.contains("fail") {
                    status = "unknown_error"
                    break
                }
            }
            if !relevantLines.isEmpty {
                platforms[key] = status
            }
        }

        // 推断整体 ok：所有已检测平台均为 ready
        let ok: Bool
        if platforms.isEmpty {
            // doctor 无平台输出 → 视 exit code 0 为 ok
            ok = !lower.contains("error") && !lower.contains("fail")
        } else {
            ok = platforms.values.allSatisfy { $0 == "ready" }
        }

        return (ok, platforms, raw)
    }

    private func buildDoctorJSON(ok: Bool, platforms: [String: String], raw: String) -> String {
        let obj: [String: Any] = [
            "ok": ok,
            "platforms": platforms,
            "raw": raw,
        ]
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"platforms":{},"raw":"serialize_failed"}"#
        }
        return json
    }

    // MARK: - Hermes 向导进度位图（PR-3）

    func getHermesWizardState(
        username: String,
        profileID: String,
        withReply reply: @escaping (String) -> Void
    ) {
        helperLog("Hermes get wizard state profile=\(profileID) @\(username)")
        reply(HermesWizardState.get(username: username, profileID: profileID))
    }

    func updateHermesWizardState(
        username: String,
        profileID: String,
        patchJSON: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("Hermes update wizard state profile=\(profileID) @\(username)")
        do {
            try HermesWizardState.update(username: username, profileID: profileID, patchJSON: patchJSON)
            reply(true, nil)
        } catch {
            helperLog("Hermes update wizard state 失败 profile=\(profileID) @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func clearHermesWizardState(
        username: String,
        profileID: String,
        withReply reply: @escaping (Bool) -> Void
    ) {
        helperLog("Hermes clear wizard state profile=\(profileID) @\(username)")
        do {
            try HermesWizardState.clear(username: username, profileID: profileID)
            reply(true)
        } catch {
            helperLog("Hermes clear wizard state 失败 profile=\(profileID) @\(username): \(error.localizedDescription)", level: .error)
            reply(false)
        }
    }

    // MARK: - Hermes 自启白名单（F2）

    func getHermesAutostartWhitelist(username: String, withReply reply: @escaping (String) -> Void) {
        helperLog("Hermes get autostart whitelist @\(username)")
        let profiles = HermesAutostartList.load(username: username)
        let obj: [String: Any] = [
            "schemaVersion": 1,
            "profiles": profiles.sorted(),
        ]
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            reply(#"{"schemaVersion":1,"profiles":["main"]}"#)
            return
        }
        reply(json)
    }

    func setHermesAutostartProfile(
        username: String,
        profileID: String,
        enabled: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("Hermes set autostart profile=\(profileID) enabled=\(enabled) @\(username)")
        do {
            if enabled {
                try HermesAutostartList.add(username: username, profileID: profileID)
            } else {
                // 显式禁用（包括 main）：从白名单移除
                // 当 main 被禁用时，remove 会将文件持久化为 profiles=[]，
                // 确保下次 load 看到文件且 profiles 为空，不再 fallback 到 ["main"]
                try HermesAutostartList.remove(username: username, profileID: profileID)
            }
            reply(true, nil)
        } catch {
            helperLog("Hermes set autostart 失败 profile=\(profileID) @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - 辅助

    /// Hermes 安装日志路径（world-readable，供 App/CLI 实时读取）
    private func hermesInitLogURL(username: String) -> URL {
        let path = "/tmp/clawdhome-hermes-\(username).log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: 0o640]
            )
        }
        return URL(fileURLWithPath: path)
    }
}
