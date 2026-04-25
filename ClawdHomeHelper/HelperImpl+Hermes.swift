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

    // MARK: - 生命周期

    func startHermesGateway(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("Hermes 启动 @\(username)")
        do {
            let uid = try UserManager.uid(for: username)
            try HermesGatewayManager.startGateway(username: username, uid: uid)
            reply(true, nil)
        } catch {
            helperLog("Hermes 启动失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func stopHermesGateway(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("Hermes 停止 @\(username)")
        do {
            let uid = try UserManager.uid(for: username)
            try HermesGatewayManager.stopGateway(username: username, uid: uid)
            reply(true, nil)
        } catch {
            helperLog("Hermes 停止失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func getHermesGatewayStatus(username: String, withReply reply: @escaping (Bool, Int32) -> Void) {
        let (running, pid) = HermesGatewayManager.status(username: username)
        reply(running, pid)
    }

    // MARK: - 初始化配置

    func applyHermesInitConfig(
        username: String,
        payloadJSON: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("Hermes apply init config @\(username) bytes=\(payloadJSON.utf8.count)")
        do {
            try HermesConfigWriter.apply(username: username, payloadJSON: payloadJSON)
            reply(true, nil)
        } catch {
            helperLog("Hermes apply init config 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func getHermesInitSummary(username: String, withReply reply: @escaping (String) -> Void) {
        helperLog("Hermes get init summary @\(username)")
        reply(HermesConfigWriter.initSummaryJSON(username: username))
    }

    func validateHermesInitConfig(
        username: String,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        helperLog("Hermes validate init config @\(username)")
        reply(true, HermesConfigWriter.validateJSON(username: username))
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
