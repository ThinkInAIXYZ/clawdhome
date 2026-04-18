// ClawdHomeHelper/HelperImpl+Plugin.swift
// OpenClaw 插件管理 XPC 实现（v2）
// 对应 HelperProtocol：installOpenclawPlugin / listOpenclawPlugins / removeOpenclawPlugin / runChannelLogin

import Foundation

extension ClawdHomeHelperImpl {

    func installOpenclawPlugin(
        username: String,
        packageSpec: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("[plugin] installOpenclawPlugin @\(username) pkg=\(packageSpec)")
        let logURL = initLogURL(username: username)
        do {
            try PluginManager.installPlugin(username: username, packageSpec: packageSpec, logURL: logURL)
            helperLog("[plugin] installOpenclawPlugin 成功 @\(username) pkg=\(packageSpec)")
            reply(true, nil)
        } catch {
            helperLog("[plugin] installOpenclawPlugin 失败 @\(username) pkg=\(packageSpec): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func listOpenclawPlugins(
        username: String,
        withReply reply: @escaping (String?, String?) -> Void
    ) {
        helperLog("[plugin] listOpenclawPlugins @\(username)")
        do {
            let json = try PluginManager.listPlugins(username: username)
            reply(json, nil)
        } catch {
            helperLog("[plugin] listOpenclawPlugins 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(nil, error.localizedDescription)
        }
    }

    func removeOpenclawPlugin(
        username: String,
        packageSpec: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("[plugin] removeOpenclawPlugin @\(username) pkg=\(packageSpec)")
        let logURL = initLogURL(username: username)
        do {
            try PluginManager.removePlugin(username: username, packageSpec: packageSpec, logURL: logURL)
            helperLog("[plugin] removeOpenclawPlugin 成功 @\(username) pkg=\(packageSpec)")
            reply(true, nil)
        } catch {
            helperLog("[plugin] removeOpenclawPlugin 失败 @\(username) pkg=\(packageSpec): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func runChannelLogin(
        username: String,
        argsJSON: String,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        guard let args = try? JSONDecoder().decode([String].self, from: Data(argsJSON.utf8)) else {
            reply(false, "参数解析失败")
            return
        }
        helperLog("[plugin] runChannelLogin @\(username) args=\(args.joined(separator: " "))")
        let logURL = initLogURL(username: username)
        do {
            let output = try PluginManager.runChannelLogin(username: username, args: args, logURL: logURL)
            helperLog("[plugin] runChannelLogin 成功 @\(username)")
            reply(true, output)
        } catch {
            helperLog("[plugin] runChannelLogin 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func applyV2Config(
        username: String,
        configJSON: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("[plugin] applyV2Config @\(username) bytes=\(configJSON.utf8.count)")
        do {
            guard let data = configJSON.data(using: .utf8) else {
                reply(false, "配置 JSON 编码失败")
                return
            }
            let config = try JSONDecoder().decode(ShrimpConfigV2.self, from: data)
            try OpenclawConfigSerializerV2.writeShrimpConfig(config, username: username)
            helperLog("[plugin] applyV2Config 成功 @\(username)")
            reply(true, nil)
        } catch {
            helperLog("[plugin] applyV2Config 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }
}
