// ClawdHomeHelper/HelperImpl+BrowserAccount.swift
// XPC surface for per-user browser accounts.

import Foundation

extension ClawdHomeHelperImpl {
    private func browserRuntimeLogURLs(username: String) -> [URL] {
        let initURL = initLogURL(username: username)
        let hermesPath = "/tmp/clawdhome-hermes-\(username).log"
        if !FileManager.default.fileExists(atPath: hermesPath) {
            FileManager.default.createFile(
                atPath: hermesPath,
                contents: nil,
                attributes: [.posixPermissions: 0o640]
            )
        }
        let hermesURL = URL(fileURLWithPath: hermesPath)
        return [initURL, hermesURL]
    }

    private func appendBrowserRuntimeLog(_ message: String, username: String) {
        let data = Data(message.utf8)
        for url in browserRuntimeLogURLs(username: username) {
            guard let handle = FileHandle(forWritingAtPath: url.path) else { continue }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }

    func openBrowserAccount(username: String, withReply reply: @escaping (Bool, String) -> Void) {
        helperLog("[browser-account] open request @\(username)")
        do {
            let session = try BrowserAccountManager.open(username: username)
            let data = try JSONEncoder().encode(session)
            reply(true, String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            helperLog("[browser-account] open failed @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func openBrowserAccountURL(username: String, url: String, withReply reply: @escaping (Bool, String) -> Void) {
        helperLog("[browser-account] open url request @\(username) url=\(url)")
        do {
            try BrowserAccountManager.openURL(username: username, url: url)
            reply(true, "")
        } catch {
            helperLog("[browser-account] open url failed @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func getBrowserAccountStatus(username: String, withReply reply: @escaping (String) -> Void) {
        let status = BrowserAccountManager.status(username: username)
        let data = try? JSONEncoder().encode(status)
        reply(data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
    }

    func resetBrowserAccount(username: String, withReply reply: @escaping (Bool, String) -> Void) {
        helperLog("[browser-account] reset request @\(username)")
        do {
            let status = try BrowserAccountManager.reset(username: username)
            let data = try JSONEncoder().encode(status)
            reply(true, String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            helperLog("[browser-account] reset failed @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func installBrowserAccountTool(username: String, withReply reply: @escaping (Bool, String) -> Void) {
        helperLog("[browser-account] install tool request @\(username)")
        do {
            try BrowserAccountManager.prepareForRuntimeInstall(username: username)
            let status = BrowserAccountManager.status(username: username)
            let data = try JSONEncoder().encode(status)
            reply(true, String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            helperLog("[browser-account] install tool failed @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func uninstallBrowserAccountTool(username: String, withReply reply: @escaping (Bool, String) -> Void) {
        helperLog("[browser-account] uninstall tool request @\(username)")
        do {
            let status = try BrowserAccountManager.uninstallTool(username: username)
            let data = try JSONEncoder().encode(status)
            reply(true, String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            helperLog("[browser-account] uninstall tool failed @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func prepareBrowserAccountForRuntimeInstall(username: String, withReply reply: @escaping (Bool, String) -> Void) {
        helperLog("[browser-account] prepare runtime install request @\(username)")
        do {
            appendBrowserRuntimeLog("→ 准备安装浏览器工具与预热浏览器账号…\n", username: username)
            try BrowserAccountManager.prepareForRuntimeInstall(username: username)
            appendBrowserRuntimeLog("✓ 浏览器工具与账号预热完成。\n", username: username)
            reply(true, "")
        } catch {
            helperLog("[browser-account] prepare runtime install failed @\(username): \(error.localizedDescription)", level: .error)
            appendBrowserRuntimeLog("✗ 浏览器工具安装失败：\(error.localizedDescription)\n", username: username)
            reply(false, error.localizedDescription)
        }
    }

    func installOpenCLI(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[browser-account] install opencli request @\(username)")
        do {
            let logURL = initLogURL(username: username)
            appendBrowserRuntimeLog("→ 安装 OpenCLI…\n", username: username)
            try BrowserAccountManager.installOpenCLI(username: username, logURL: logURL)
            appendBrowserRuntimeLog("✓ OpenCLI 安装完成。\n", username: username)
            reply(true, nil)
        } catch {
            helperLog("[browser-account] install opencli failed @\(username): \(error.localizedDescription)", level: .error)
            appendBrowserRuntimeLog("✗ OpenCLI 安装失败：\(error.localizedDescription)\n", username: username)
            reply(false, error.localizedDescription)
        }
    }

    func getOpenCLIVersion(username: String, withReply reply: @escaping (String) -> Void) {
        reply(BrowserAccountManager.openCLIVersion(username: username) ?? "")
    }

    func runOpenCLIDoctor(username: String, withReply reply: @escaping (Bool, String) -> Void) {
        helperLog("[browser-account] run opencli doctor @\(username)")
        do {
            let output = try BrowserAccountManager.runOpenCLIDoctor(username: username)
            reply(true, output)
        } catch {
            helperLog("[browser-account] opencli doctor failed @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }
}
