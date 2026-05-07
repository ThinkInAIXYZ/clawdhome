// ClawdHomeCLI/Commands/ExecCommand.swift
// clawdhome exec <name> — 以实例用户身份进入交互式终端

import Foundation

enum ExecCommand {
    private static func setEnv(_ envArgs: inout [String], key: String, value: String) {
        let prefix = "\(key)="
        if let idx = envArgs.firstIndex(where: { $0.hasPrefix(prefix) }) {
            envArgs[idx] = "\(key)=\(value)"
        } else {
            envArgs.append("\(key)=\(value)")
        }
    }

    static func run(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome exec <name>")
            exit(1)
        }

        // 1. 验证用户存在并获取环境信息
        let proxy = try client.proxy()

        let group = DispatchGroup()
        var nodeInstalled = false
        var gatewayURL = ""

        group.enter()
        proxy.isNodeInstalled(username: username) { installed in
            nodeInstalled = installed; group.leave()
        }

        group.enter()
        proxy.getGatewayURL(username: username) { url in
            gatewayURL = url; group.leave()
        }

        group.wait()

        // 2. 构建环境变量
        let home = "/Users/\(username)"
        let brewBin = "\(home)/.brew/bin"
        let npmGlobal = "\(home)/.npm-global"
        let npmGlobalBin = "\(npmGlobal)/bin"
        let npmSharedCache = "/var/lib/clawdhome/cache/npm"

        // 构建 PATH（与 ConfigWriter.buildNodePath 一致的逻辑）
        var pathComponents = [npmGlobalBin, brewBin]
        for version in ["node", "node@24", "node@22", "node@20", "node@18"] {
            pathComponents.append("\(home)/.brew/opt/\(version)/bin")
        }
        let libNodeRoot = "\(home)/.brew/lib/nodejs"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: libNodeRoot).sorted(by: >) {
            for entry in entries where entry.hasPrefix("node-") {
                let binPath = "\(libNodeRoot)/\(entry)/bin"
                if FileManager.default.isExecutableFile(atPath: "\(binPath)/node") {
                    pathComponents.append(binPath)
                }
            }
        }
        pathComponents.append(contentsOf: ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        let nodePath = pathComponents.joined(separator: ":")

        // 3. 构建 env 参数
        var envArgs: [String] = [
            "HOME=\(home)",
            "PATH=\(nodePath)",
            "HOMEBREW_PREFIX=\(home)/.brew",
            "HOMEBREW_CELLAR=\(home)/.brew/Cellar",
            "HOMEBREW_REPOSITORY=\(home)/.brew",
            "NPM_CONFIG_PREFIX=\(npmGlobal)",
            "npm_config_prefix=\(npmGlobal)",
            "NPM_CONFIG_CACHE=\(npmSharedCache)",
            "npm_config_cache=\(npmSharedCache)",
            "NPM_CONFIG_USERCONFIG=\(home)/.npmrc",
            "npm_config_userconfig=\(home)/.npmrc",
            "TERM=\(ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color")",
            "LANG=\(ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8")",
        ]

        // 透传终端相关环境，尽量贴近当前会话体验（颜色、locale 等）
        for key in [
            "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM",
            "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "LANG", "TZ",
            "SSH_AUTH_SOCK",
        ] {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
                setEnv(&envArgs, key: key, value: value)
            }
        }

        // 追加代理环境（如果存在）
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                     "http_proxy", "https_proxy", "all_proxy", "no_proxy"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                envArgs.append("\(key)=\(value)")
            }
        }

        if !gatewayURL.isEmpty {
            Output.printErr("Gateway: \(gatewayURL)")
        }
        Output.printErr("进入 \(username) 的 shell 环境...")

        // 4. exec 替换当前进程
        // 关键：先切到目标用户 HOME，避免继承当前目录导致 getcwd PermissionError。
        let shellBootstrap = "cd \"$HOME\" 2>/dev/null || cd /; exec /bin/zsh -l"
        let fullArgs = ["/usr/bin/sudo", "-u", username, "-H", "/usr/bin/env"] + envArgs + ["/bin/zsh", "-lc", shellBootstrap]
        let cArgs = fullArgs.map { strdup($0) } + [nil]
        execvp(cArgs[0]!, cArgs)

        // 如果 exec 失败
        perror("exec failed")
        exit(1)
    }
}
