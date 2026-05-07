// ClawdHomeHelper/HelperImpl+BrowserAccount.swift
// XPC surface for per-user browser accounts.

import Foundation

extension ClawdHomeHelperImpl {
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
            let status = try BrowserAccountManager.installTool(username: username)
            let data = try JSONEncoder().encode(status)
            reply(true, String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            helperLog("[browser-account] install tool failed @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func prepareBrowserAccountForRuntimeInstall(username: String, withReply reply: @escaping (Bool, String) -> Void) {
        helperLog("[browser-account] prepare runtime install request @\(username)")
        do {
            try BrowserAccountManager.prepareForRuntimeInstall(username: username)
            reply(true, "")
        } catch {
            helperLog("[browser-account] prepare runtime install failed @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }
}
