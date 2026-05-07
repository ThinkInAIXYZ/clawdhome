// ClawdHomeHelper/Operations/BrowserAccountManager.swift
// Manages per-shrimp Chrome profiles and the local CDP bridge session.

import Foundation
import SystemConfiguration

enum BrowserAccountError: LocalizedError {
    case invalidUsername
    case chromeNotFound
    case noConsoleSession
    case devToolsPortUnavailable
    case sessionMissing

    var errorDescription: String? {
        switch self {
        case .invalidUsername:
            return "无效的用户名"
        case .chromeNotFound:
            return "未找到 Google Chrome，请先安装 Chrome"
        case .noConsoleSession:
            return "未检测到可交互的 macOS 桌面登录会话"
        case .devToolsPortUnavailable:
            return "Chrome 已启动，但未能获取 DevTools 调试端口"
        case .sessionMissing:
            return "浏览器账号尚未打开，请先在 ClawdHome 中打开浏览器账号"
        }
    }
}

enum BrowserAccountManager {
    private static let chromeAppPath = "/Applications/Google Chrome.app"

    static func open(username: String) throws -> BrowserAccountSession {
        let context = try resolveContext(username: username)
        guard FileManager.default.fileExists(atPath: chromeAppPath) else {
            throw BrowserAccountError.chromeNotFound
        }

        try prepareProfileDirectory(context.paths.profileDirectory.path, consoleUsername: context.consoleUsername)
        try removeStaleActivePortIfNeeded(context.paths.devToolsActivePortFile.path)

        let args = [
            "asuser", "\(context.consoleUID)",
            "/usr/bin/sudo", "-u", context.consoleUsername, "-H",
            "/usr/bin/open", "-na", "Google Chrome", "--args",
            "--user-data-dir=\(context.paths.profileDirectory.path)",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=0",
            "--no-first-run",
            "--new-window",
            "about:blank",
        ]
        try run("/bin/launchctl", args: args)

        guard let activePort = waitForActivePort(filePath: context.paths.devToolsActivePortFile.path, timeout: 8) else {
            throw BrowserAccountError.devToolsPortUnavailable
        }

        let session = BrowserAccountSession(
            username: username,
            profilePath: context.paths.profileDirectory.path,
            devToolsActivePortPath: context.paths.devToolsActivePortFile.path,
            httpEndpoint: activePort.httpEndpoint,
            webSocketDebuggerURL: activePort.webSocketDebuggerURL,
            cdpPort: activePort.port,
            launchedAt: Date().timeIntervalSince1970,
            consoleUsername: context.consoleUsername
        )
        try writeSession(session, username: username)
        return session
    }

    static func status(username: String) -> BrowserAccountStatus {
        guard let context = try? resolveContext(username: username) else {
            return BrowserAccountStatus(
                username: username,
                profilePath: "",
                sessionPath: "/Users/\(username)/\(BrowserAccountPaths.sessionRelativePath)",
                toolPath: "/Users/\(username)/\(BrowserAccountPaths.toolExecutableRelativePath)",
                toolInstalled: false,
                sessionExists: false,
                browserReachable: false,
                httpEndpoint: nil,
                message: "用户不存在或用户名无效"
            )
        }

        let sessionPath = sessionPath(username: username)
        let toolPath = "/Users/\(username)/\(BrowserAccountPaths.toolExecutableRelativePath)"
        let session = readSession(username: username)
        let reachable = session.flatMap { isReachable(httpEndpoint: $0.httpEndpoint) } ?? false
        let message: String
        if reachable {
            message = "浏览器账号运行中"
        } else if session != nil {
            message = "已记录浏览器账号，但当前 Chrome 不可连接"
        } else {
            message = "尚未打开浏览器账号"
        }
        return BrowserAccountStatus(
            username: username,
            profilePath: session?.profilePath ?? context.paths.profileDirectory.path,
            sessionPath: sessionPath,
            toolPath: toolPath,
            toolInstalled: FileManager.default.isExecutableFile(atPath: toolPath),
            sessionExists: FileManager.default.fileExists(atPath: sessionPath),
            browserReachable: reachable,
            httpEndpoint: session?.httpEndpoint,
            message: message
        )
    }

    static func reset(username: String) throws -> BrowserAccountStatus {
        let context = try resolveContext(username: username)
        let fm = FileManager.default
        try backupAndRemoveProfileIfNeeded(context.paths.profileDirectory.path, fileManager: fm)
        try backupAndRemoveProfileIfNeeded("/Users/\(username)/\(BrowserAccountPaths.toolBrowserProfileRelativePath)", fileManager: fm)
        let session = sessionPath(username: username)
        if fm.fileExists(atPath: session) {
            try fm.removeItem(atPath: session)
        }
        return status(username: username)
    }

    private static func backupAndRemoveProfileIfNeeded(_ profile: String, fileManager fm: FileManager) throws {
        if fm.fileExists(atPath: profile) {
            let stamp = timestamp()
            let backup = "\(profile).backup-\(stamp)"
            try fm.moveItem(atPath: profile, toPath: backup)
        }
    }

    static func installTool(username: String) throws -> BrowserAccountStatus {
        guard BrowserAccountPaths.isValidUsername(username) else {
            throw BrowserAccountError.invalidUsername
        }
        let toolDir = "/Users/\(username)/\(BrowserAccountPaths.toolDirectoryRelativePath)"
        let toolPath = "/Users/\(username)/\(BrowserAccountPaths.toolExecutableRelativePath)"
        let binDir = "/Users/\(username)/.npm-global/bin"
        let binPath = "\(binDir)/clawdhome-browser"

        try FileManager.default.createDirectory(atPath: toolDir, withIntermediateDirectories: true)
        try FilePermissionHelper.chownRecursive("/Users/\(username)/.openclaw/tools", owner: username)
        try browserToolScript.write(toFile: toolPath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chownRecursive(toolDir, owner: username)
        try FilePermissionHelper.chmod(toolPath, mode: "755")
        try installPrivilegedBrowserLauncher(username: username, toolDir: toolDir)

        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        try FilePermissionHelper.chownRecursive("/Users/\(username)/.npm-global", owner: username)
        let wrapper = """
        #!/bin/zsh
        exec /usr/bin/env python3 "\(toolPath)" "$@"
        """
        try wrapper.write(toFile: binPath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chown(binPath, owner: username)
        try FilePermissionHelper.chmod(binPath, mode: "755")
        try installBrowserCommandWrappers(username: username, binDir: binDir, toolPath: toolPath)
        try installOpenCLIWrapperIfPresent(username: username, binDir: binDir, toolPath: toolPath)

        try appendToolsGuidanceIfNeeded(username: username)
        return status(username: username)
    }

    private static func installPrivilegedBrowserLauncher(username: String, toolDir: String) throws {
        let sourcePath = "\(toolDir)/clawdhome-browser-launcher.c"
        let launcherPath = "/Users/\(username)/\(BrowserAccountPaths.toolLauncherRelativePath)"
        try browserLauncherSource.write(toFile: sourcePath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chown(sourcePath, owner: username)
        try FilePermissionHelper.chmod(sourcePath, mode: "600")
        try run("/usr/bin/clang", args: [sourcePath, "-o", launcherPath])
        try FilePermissionHelper.chown(launcherPath, owner: "root", group: "wheel")
        try FilePermissionHelper.chmod(launcherPath, mode: "4755")
    }

    private static func installBrowserCommandWrappers(username: String, binDir: String, toolPath: String) throws {
        for name in BrowserAccountPaths.browserCommandWrapperNames {
            let path = "\(binDir)/\(name)"
            let wrapper = browserCommandWrapperScript(commandName: name, toolPath: toolPath)
            try wrapper.write(toFile: path, atomically: true, encoding: .utf8)
            try FilePermissionHelper.chown(path, owner: username)
            try FilePermissionHelper.chmod(path, mode: "755")
        }
    }

    private static func browserCommandWrapperScript(commandName: String, toolPath: String) -> String {
        let systemOpenFallback = commandName == "open" ? """
        exec /usr/bin/open "$@"
        """ : """
        echo "\(commandName): ClawdHome 已接管浏览器打开操作；请传入 http(s) URL。" >&2
        exit 1
        """
        return """
        #!/bin/zsh
        set -e

        for arg in "$@"; do
          case "$arg" in
            http://*|https://*)
              exec /usr/bin/env python3 "\(toolPath)" open "$arg"
              ;;
          esac
        done

        if [ "$#" -eq 0 ]; then
          exec /usr/bin/env python3 "\(toolPath)" open "https://clawdhome.ai"
        fi

        \(systemOpenFallback)
        """
    }

    private static func installOpenCLIWrapperIfPresent(username: String, binDir: String, toolPath: String) throws {
        let opencliPath = "\(binDir)/opencli"
        let realPath = "\(binDir)/\(BrowserAccountPaths.openCLIRealExecutableName)"
        let fm = FileManager.default
        guard fm.fileExists(atPath: opencliPath) || fm.fileExists(atPath: realPath) else {
            return
        }

        let existing = (try? String(contentsOfFile: opencliPath, encoding: .utf8)) ?? ""
        if !existing.contains("CLAWDHOME_OPENCLI_WRAPPER"), fm.fileExists(atPath: opencliPath) {
            if fm.fileExists(atPath: realPath) {
                let backupPath = "\(opencliPath).backup-\(timestamp())"
                try fm.moveItem(atPath: opencliPath, toPath: backupPath)
                try FilePermissionHelper.chown(backupPath, owner: username)
            } else {
                try fm.moveItem(atPath: opencliPath, toPath: realPath)
                try FilePermissionHelper.chown(realPath, owner: username)
                try FilePermissionHelper.chmod(realPath, mode: "755")
            }
        }

        let daemonPath = "\(binDir)/../lib/node_modules/@jackwener/opencli/dist/src/daemon.js"
        let wrapper = openCLIWrapperScript(toolPath: toolPath, realPath: realPath, daemonPath: daemonPath)
        try wrapper.write(toFile: opencliPath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chown(opencliPath, owner: username)
        try FilePermissionHelper.chmod(opencliPath, mode: "755")
    }

    private static func openCLIWrapperScript(toolPath: String, realPath: String, daemonPath: String) -> String {
        """
        #!/bin/zsh
        # CLAWDHOME_OPENCLI_WRAPPER
        set -e

        CLAWDHOME_BROWSER_HIDE=1 /usr/bin/env python3 "\(toolPath)" open "https://clawdhome.ai" >/dev/null 2>&1 || {
          echo "ClawdHome: 已尝试自动打开该虾专属 Chrome，但启动失败。请先在 ClawdHome 中打开浏览器账号。" >&2
        }

        port="${OPENCLI_DAEMON_PORT:-19825}"
        if ! /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
          mkdir -p "$HOME/.opencli"
          /usr/bin/nohup /usr/bin/env node "\(daemonPath)" >> "$HOME/.opencli/clawdhome-daemon.log" 2>&1 &
          for _ in 1 2 3 4 5 6 7 8 9 10; do
            /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && break
            sleep 0.2
          done
        fi

        for _ in 1 2 3 4 5 6 7 8 9 10; do
          status_json="$(/usr/bin/curl -fsS -H 'X-OpenCLI: 1' "http://127.0.0.1:$port/status" 2>/dev/null || true)"
          echo "$status_json" | /usr/bin/grep -q '"extensionConnected":true' && break
          sleep 0.5
        done

        exec "\(realPath)" "$@"
        """
    }

    private struct Context {
        let consoleUsername: String
        let consoleUID: uid_t
        let paths: BrowserAccountPaths
    }

    private static func resolveContext(username: String) throws -> Context {
        guard BrowserAccountPaths.isValidUsername(username) else {
            throw BrowserAccountError.invalidUsername
        }
        let (consoleUsername, consoleUID) = try resolveConsoleSession()
        let appSupport = URL(fileURLWithPath: "/Users/\(consoleUsername)/Library/Application Support/ClawdHome")
        return Context(
            consoleUsername: consoleUsername,
            consoleUID: consoleUID,
            paths: BrowserAccountPaths(username: username, appSupportDirectory: appSupport)
        )
    }

    private static func resolveConsoleSession() throws -> (username: String, uid: uid_t) {
        var uid: uid_t = 0
        guard let cfUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil), uid != 0 else {
            throw BrowserAccountError.noConsoleSession
        }
        let username = (cfUser as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, username != "loginwindow" else {
            throw BrowserAccountError.noConsoleSession
        }
        return (username, uid)
    }

    private static func prepareProfileDirectory(_ path: String, consoleUsername: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FilePermissionHelper.chownRecursive(path, owner: consoleUsername)
        try FilePermissionHelper.chmod(path, mode: "700")
    }

    private static func removeStaleActivePortIfNeeded(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path),
              let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let activePort = BrowserAccountActivePort.parse(raw),
              !isReachable(httpEndpoint: activePort.httpEndpoint) else {
            return
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func waitForActivePort(filePath: String, timeout: TimeInterval) -> BrowserAccountActivePort? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: filePath, encoding: .utf8),
               let activePort = BrowserAccountActivePort.parse(raw),
               isReachable(httpEndpoint: activePort.httpEndpoint) {
                return activePort
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private static func writeSession(_ session: BrowserAccountSession, username: String) throws {
        let path = sessionPath(username: username)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FilePermissionHelper.chown(path, owner: username)
        try FilePermissionHelper.chmod(path, mode: "600")
    }

    private static func readSession(username: String) -> BrowserAccountSession? {
        let path = sessionPath(username: username)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(BrowserAccountSession.self, from: data)
    }

    private static func sessionPath(username: String) -> String {
        "/Users/\(username)/\(BrowserAccountPaths.sessionRelativePath)"
    }

    private static func isReachable(httpEndpoint: String) -> Bool {
        guard let url = URL(string: "\(httpEndpoint)/json/version") else { return false }
        return (try? Data(contentsOf: url)) != nil
    }

    private static func appendToolsGuidanceIfNeeded(username: String) throws {
        let relativePath = ".openclaw/workspace/TOOLS.md"
        try UserFileManager.createDirectory(username: username, relativePath: ".openclaw/workspace")

        let marker = "clawdhome_browser_account"
        let guidance = """

        ## ClawdHome 浏览器账号

        <!-- clawdhome_browser_account -->

        你可以使用 `clawdhome-browser` 操作该虾专属的已登录 Chrome 浏览器账号。

        - `clawdhome-browser status`：检查浏览器账号是否已打开。
        - `clawdhome-browser open <url>`：启动/复用该虾专属 Chrome，并打开网页。
        - `clawdhome-browser launch [url]`：底层启动命令，通常无需直接使用。
        - `clawdhome-browser title`：读取当前页面标题。
        - `clawdhome-browser extract-text`：提取当前页面正文。
        - `clawdhome-browser screenshot`：保存当前页面截图。

        常见浏览器打开命令已被接管：`open <url>`、`google-chrome <url>`、`chrome <url>`、`chromium <url>`、`xdg-open <url>` 会自动跳到 `clawdhome-browser open <url>`；无 URL 时默认打开 `https://clawdhome.ai`。

        如果该虾已安装 `opencli`，ClawdHome 会把真实入口保存在 `opencli.clawdhome-real`，并用 wrapper 接管 `opencli`：每次运行 OpenCLI 前会先自动执行 `clawdhome-browser open https://clawdhome.ai`，确保 Browser Bridge 有机会连接到该虾专属 Chrome。

        如果虾用户没有 macOS 图形会话，`launch` 可能会被系统拒绝；此时请让用户在 ClawdHome 中点击“打开浏览器账号”完成 fallback。
        """
        let existing = (try? UserFileManager.readFile(username: username, relativePath: relativePath))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard !existing.contains(marker) else { return }
        let next = existing.isEmpty ? guidance.trimmingCharacters(in: .whitespacesAndNewlines) : existing + guidance
        try UserFileManager.writeFile(username: username, relativePath: relativePath, data: Data(next.utf8))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private let browserToolScript = #"""
#!/usr/bin/env python3
import base64
import datetime
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request

SESSION_PATH = os.path.expanduser("~/.openclaw/clawdhome-browser-session.json")
PROFILE_PATH = os.path.expanduser("~/.openclaw/browser-profile")
ACTIVE_PORT_PATH = os.path.join(PROFILE_PATH, "DevToolsActivePort")
LAUNCHER_PATH = os.path.expanduser("~/.openclaw/tools/clawdhome-browser/clawdhome-browser-launcher")
CHROME_APP = "/Applications/Google Chrome.app"

def fail(message, code=1):
    print(message, file=sys.stderr)
    sys.exit(code)

def load_session():
    if not os.path.exists(SESSION_PATH):
        fail("浏览器账号尚未打开。请先运行 clawdhome-browser launch，或在 ClawdHome 中点击“打开浏览器账号”。")
    with open(SESSION_PATH, "r", encoding="utf-8") as f:
        return json.load(f)

def load_session_if_present():
    if not os.path.exists(SESSION_PATH):
        return None
    try:
        with open(SESSION_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def request_json(url, method="GET"):
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=5) as res:
        return json.loads(res.read().decode("utf-8"))

def endpoint_reachable(endpoint):
    try:
        request_json(endpoint.rstrip("/") + "/json/version")
        return True
    except Exception:
        return False

def should_hide_browser():
    return os.environ.get("CLAWDHOME_BROWSER_HIDE") == "1"

def hide_browser_if_requested():
    if not should_hide_browser():
        return
    subprocess.run(
        ["/usr/bin/osascript", "-e", 'tell application "Google Chrome" to hide'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

def parse_active_port(active_port_path=ACTIVE_PORT_PATH):
    if not os.path.exists(active_port_path):
        return None
    with open(active_port_path, "r", encoding="utf-8") as f:
        lines = [line.strip() for line in f.readlines() if line.strip()]
    if len(lines) < 2:
        return None
    try:
        port = int(lines[0])
    except ValueError:
        return None
    if port <= 0 or not lines[1].startswith("/"):
        return None
    return {
        "port": port,
        "httpEndpoint": f"http://127.0.0.1:{port}",
        "webSocketDebuggerURL": f"ws://127.0.0.1:{port}{lines[1]}",
    }

def save_session(active_port, profile_path=PROFILE_PATH, active_port_path=ACTIVE_PORT_PATH, base_session=None):
    os.makedirs(os.path.dirname(SESSION_PATH), exist_ok=True)
    session = {
        "username": (base_session or {}).get("username", os.environ.get("USER", "")),
        "profilePath": profile_path,
        "devToolsActivePortPath": active_port_path,
        "httpEndpoint": active_port["httpEndpoint"],
        "webSocketDebuggerURL": active_port["webSocketDebuggerURL"],
        "cdpPort": active_port["port"],
        "launchedAt": time.time(),
        "consoleUsername": (base_session or {}).get("consoleUsername", os.environ.get("USER", "")),
    }
    with open(SESSION_PATH, "w", encoding="utf-8") as f:
        json.dump(session, f, ensure_ascii=False, indent=2)
    os.chmod(SESSION_PATH, 0o600)
    return session

def current_session_reachable():
    session = load_session_if_present()
    if not session:
        return None
    if endpoint_reachable(session.get("httpEndpoint", "")):
        return session
    return None

def http_endpoint():
    return load_session()["httpEndpoint"].rstrip("/")

def list_pages():
    return [p for p in request_json(http_endpoint() + "/json/list") if p.get("type") == "page"]

def normalize_url_for_match(url):
    parsed = urllib.parse.urlparse(url)
    scheme = parsed.scheme.lower()
    netloc = parsed.netloc.lower()
    if scheme == "https" and netloc.endswith(":443"):
        netloc = netloc[:-4]
    if scheme == "http" and netloc.endswith(":80"):
        netloc = netloc[:-3]
    if netloc == "clawdhome.ai":
        netloc = "clawdhome.app"
    path = parsed.path or "/"
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/")
    return urllib.parse.urlunparse((scheme, netloc, path, "", parsed.query, ""))

def find_open_page(url):
    wanted = normalize_url_for_match(url)
    for page in list_pages():
        current = page.get("url", "")
        if current and normalize_url_for_match(current) == wanted:
            return page
    return None

def activate_page(page):
    target_id = page.get("id")
    if not target_id:
        return
    try:
        urllib.request.urlopen(http_endpoint() + "/json/activate/" + urllib.parse.quote(target_id, safe=""), timeout=2).read()
    except Exception:
        pass

def ensure_page():
    pages = list_pages()
    if pages:
        return pages[0]
    return request_json(http_endpoint() + "/json/new?about%3Ablank", method="PUT")

class CDP:
    def __init__(self, websocket_url):
        parsed = urllib.parse.urlparse(websocket_url)
        self.host = parsed.hostname or "127.0.0.1"
        self.port = parsed.port
        self.path = parsed.path
        self.sock = socket.create_connection((self.host, self.port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: {self.host}:{self.port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode("ascii"))
        response = self.sock.recv(4096)
        if b" 101 " not in response:
            raise RuntimeError("CDP WebSocket handshake failed")
        self.next_id = 1

    def send(self, method, params=None):
        msg_id = self.next_id
        self.next_id += 1
        payload = json.dumps({"id": msg_id, "method": method, "params": params or {}}).encode("utf-8")
        self._send_frame(payload)
        while True:
            data = json.loads(self._recv_frame().decode("utf-8"))
            if data.get("id") == msg_id:
                if "error" in data:
                    raise RuntimeError(data["error"].get("message", str(data["error"])))
                return data.get("result", {})

    def _send_frame(self, payload):
        header = bytearray([0x81])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", length))
        mask = os.urandom(4)
        header.extend(mask)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + masked)

    def _recv_exact(self, n):
        chunks = bytearray()
        while len(chunks) < n:
            chunk = self.sock.recv(n - len(chunks))
            if not chunk:
                raise RuntimeError("CDP WebSocket closed")
            chunks.extend(chunk)
        return bytes(chunks)

    def _recv_frame(self):
        first, second = self._recv_exact(2)
        opcode = first & 0x0F
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._recv_exact(8))[0]
        masked = second & 0x80
        mask = self._recv_exact(4) if masked else None
        payload = self._recv_exact(length)
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 8:
            raise RuntimeError("CDP WebSocket closed")
        return payload

def page_client():
    page = ensure_page()
    ws = page.get("webSocketDebuggerUrl")
    if not ws:
        fail("当前没有可控制的页面。")
    return CDP(ws)

def command_status():
    session = load_session()
    try:
        version = request_json(session["httpEndpoint"].rstrip("/") + "/json/version")
    except Exception:
        print(json.dumps({
            "ok": False,
            "endpoint": session.get("httpEndpoint", ""),
            "profilePath": session.get("profilePath", ""),
            "message": "已记录浏览器账号，但当前 Chrome 不可连接"
        }, ensure_ascii=False, indent=2))
        return
    print(json.dumps({
        "ok": True,
        "endpoint": session["httpEndpoint"],
        "browser": version.get("Browser", ""),
        "profilePath": session.get("profilePath", "")
    }, ensure_ascii=False, indent=2))

def command_launch(url=None):
    session = current_session_reachable()
    if session:
        if url:
            command_open(url)
        else:
            print(json.dumps({
                "ok": True,
                "endpoint": session["httpEndpoint"],
                "profilePath": session.get("profilePath", PROFILE_PATH),
                "message": "浏览器账号已运行"
            }, ensure_ascii=False, indent=2))
        return

    existing_session = load_session_if_present()
    launch_profile_path = (existing_session or {}).get("profilePath", PROFILE_PATH)
    launch_active_port_path = (existing_session or {}).get(
        "devToolsActivePortPath",
        os.path.join(launch_profile_path, "DevToolsActivePort"),
    )
    launch_port = int((existing_session or {}).get("cdpPort", 0) or 0)

    if not existing_session and launch_profile_path == PROFILE_PATH:
        fail("浏览器账号尚未初始化。请先在 ClawdHome 中点击一次“打开浏览器账号”，之后虾内命令会自动复用并拉起它。")

    if not os.path.exists(CHROME_APP):
        fail("未找到 Google Chrome，请先安装 Chrome。")

    if launch_profile_path == PROFILE_PATH:
        os.makedirs(launch_profile_path, exist_ok=True)
    if os.path.exists(launch_active_port_path) and os.access(launch_active_port_path, os.W_OK):
        try:
            os.remove(launch_active_port_path)
        except OSError:
            pass

    target = url or "about:blank"
    port_arg = str(launch_port) if launch_port > 0 else "0"
    if existing_session and os.path.exists(LAUNCHER_PATH) and os.access(LAUNCHER_PATH, os.X_OK):
        args = [LAUNCHER_PATH, target]
        if should_hide_browser():
            args.append("--hidden")
    else:
        args = [
        "/usr/bin/open", "-na", "Google Chrome",
        ]
        if should_hide_browser():
            args.append("-j")
        args += [
        "--args",
        f"--user-data-dir={launch_profile_path}",
        "--remote-debugging-address=127.0.0.1",
        f"--remote-debugging-port={port_arg}",
        "--no-first-run",
        "--new-window",
        target,
        ]
    try:
        subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        fail("虾用户直接启动 GUI Chrome 失败。该虾可能没有 macOS 图形会话。" + (f"\n{detail}" if detail else ""))

    deadline = time.time() + 8
    while time.time() < deadline:
        active_port = None
        if launch_port > 0:
            endpoint = f"http://127.0.0.1:{launch_port}"
            if endpoint_reachable(endpoint):
                try:
                    version = request_json(endpoint + "/json/version")
                    ws = version.get("webSocketDebuggerUrl", "")
                    ws_path = urllib.parse.urlparse(ws).path if ws else "/devtools/browser"
                except Exception:
                    ws_path = "/devtools/browser"
                active_port = {
                    "port": launch_port,
                    "httpEndpoint": endpoint,
                    "webSocketDebuggerURL": f"ws://127.0.0.1:{launch_port}{ws_path}",
                }
        else:
            active_port = parse_active_port(launch_active_port_path)
        if active_port and endpoint_reachable(active_port["httpEndpoint"]):
            session = save_session(active_port, launch_profile_path, launch_active_port_path, existing_session)
            hide_browser_if_requested()
            print(json.dumps({
                "ok": True,
                "endpoint": session["httpEndpoint"],
                "profilePath": session["profilePath"],
                "message": "浏览器账号已启动"
            }, ensure_ascii=False, indent=2))
            return
        time.sleep(0.2)

    fail("Chrome 已尝试启动，但未能读取 DevToolsActivePort。该虾可能没有可用 GUI 会话，或 Chrome 启动被 macOS 拒绝。")

def command_open(url):
    if not url:
        fail("用法: clawdhome-browser open <url>")
    if not os.path.exists(SESSION_PATH) or not current_session_reachable():
        command_launch(url)
        return
    existing_page = find_open_page(url)
    if existing_page:
        activate_page(existing_page)
        hide_browser_if_requested()
        print(url)
        return
    encoded = urllib.parse.quote(url, safe="")
    request_json(http_endpoint() + "/json/new?" + encoded, method="PUT")
    hide_browser_if_requested()
    print(url)

def command_eval(expression):
    client = page_client()
    result = client.send("Runtime.evaluate", {
        "expression": expression,
        "returnByValue": True,
        "awaitPromise": True
    })
    value = result.get("result", {}).get("value", "")
    print(value if value is not None else "")

def command_screenshot():
    client = page_client()
    client.send("Page.enable")
    result = client.send("Page.captureScreenshot", {"format": "png", "fromSurface": True})
    raw = base64.b64decode(result["data"])
    name = "clawdhome-browser-screenshot-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + ".png"
    path = os.path.abspath(name)
    with open(path, "wb") as f:
        f.write(raw)
    print(path)

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        command_status()
    elif cmd == "launch":
        command_launch(sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd == "open":
        command_open(sys.argv[2] if len(sys.argv) > 2 else "")
    elif cmd == "title":
        command_eval("document.title")
    elif cmd == "extract-text":
        command_eval("document.body ? document.body.innerText : ''")
    elif cmd == "screenshot":
        command_screenshot()
    else:
        fail("用法: clawdhome-browser status|launch [url]|open <url>|title|extract-text|screenshot")

if __name__ == "__main__":
    main()
"""#

private let browserLauncherSource = #"""
#include <ctype.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int read_file(const char *path, char *buf, size_t cap) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    size_t n = fread(buf, 1, cap - 1, f);
    buf[n] = '\0';
    fclose(f);
    return 0;
}

static int json_string(const char *json, const char *key, char *out, size_t cap) {
    char pat[128];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    char *p = strstr(json, pat);
    if (!p) return -1;
    p = strchr(p + strlen(pat), ':');
    if (!p) return -1;
    p++;
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '"') return -1;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < cap) {
        if (*p == '\\' && p[1]) p++;
        out[i++] = *p++;
    }
    out[i] = '\0';
    return i > 0 ? 0 : -1;
}

static int json_int(const char *json, const char *key) {
    char pat[128];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    char *p = strstr(json, pat);
    if (!p) return 0;
    p = strchr(p + strlen(pat), ':');
    if (!p) return 0;
    p++;
    while (*p && !isdigit((unsigned char)*p)) p++;
    return atoi(p);
}

int main(int argc, char **argv) {
    uid_t original_uid = getuid();
    if (setreuid(0, 0) != 0) {
        perror("setreuid");
        return 69;
    }

    struct passwd *pw = getpwuid(original_uid);
    if (!pw || !pw->pw_dir) {
        fprintf(stderr, "cannot resolve caller home\n");
        return 70;
    }

    char session_path[4096];
    snprintf(session_path, sizeof(session_path), "%s/.openclaw/clawdhome-browser-session.json", pw->pw_dir);
    char json[65536];
    if (read_file(session_path, json, sizeof(json)) != 0) {
        fprintf(stderr, "browser session missing: %s\n", session_path);
        return 71;
    }

    char profile[4096];
    if (json_string(json, "profilePath", profile, sizeof(profile)) != 0) {
        fprintf(stderr, "profilePath missing in session\n");
        return 72;
    }
    int port = json_int(json, "cdpPort");
    if (port <= 0 || port > 65535) {
        fprintf(stderr, "invalid cdpPort in session\n");
        return 73;
    }

    struct stat st;
    if (stat("/dev/console", &st) != 0) {
        perror("stat /dev/console");
        return 74;
    }
    struct passwd *console = getpwuid(st.st_uid);
    if (!console || !console->pw_name) {
        fprintf(stderr, "cannot resolve console user\n");
        return 75;
    }

    char uidbuf[32], portarg[128], profilearg[4096], stale[4096];
    snprintf(uidbuf, sizeof(uidbuf), "%u", (unsigned)st.st_uid);
    snprintf(portarg, sizeof(portarg), "--remote-debugging-port=%d", port);
    snprintf(profilearg, sizeof(profilearg), "--user-data-dir=%s", profile);
    const char *target = (argc > 1 && argv[1] && argv[1][0]) ? argv[1] : "about:blank";
    int hidden = argc > 2 && strcmp(argv[2], "--hidden") == 0;

    snprintf(stale, sizeof(stale), "%s/DevToolsActivePort", profile);
    unlink(stale);
    snprintf(stale, sizeof(stale), "%s/SingletonLock", profile);
    unlink(stale);
    snprintf(stale, sizeof(stale), "%s/SingletonCookie", profile);
    unlink(stale);
    snprintf(stale, sizeof(stale), "%s/SingletonSocket", profile);
    unlink(stale);

    char *args[22];
    int i = 0;
    args[i++] = "/bin/launchctl";
    args[i++] = "asuser";
    args[i++] = uidbuf;
    args[i++] = "/usr/bin/sudo";
    args[i++] = "-u";
    args[i++] = console->pw_name;
    args[i++] = "-H";
    args[i++] = "/usr/bin/open";
    args[i++] = "-na";
    args[i++] = "Google Chrome";
    if (hidden) args[i++] = "-j";
    args[i++] = "--args";
    args[i++] = profilearg;
    args[i++] = "--remote-debugging-address=127.0.0.1";
    args[i++] = portarg;
    args[i++] = "--no-first-run";
    args[i++] = "--new-window";
    args[i++] = (char *)target;
    args[i] = NULL;
    execv(args[0], args);
    perror("exec launchctl");
    return 76;
}
"""#
