import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers

private enum WikiHostLoadState: Equatable {
    case preparing
    case ready
    case blocked(String)
}

private final class WikiFileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedPath = components.queryItems?.first(where: { $0.name == "path" })?.value
        else {
            urlSchemeTask.didFailWithError(NSError(domain: "WikiFileSchemeHandler", code: 1))
            return
        }

        let fileURL = URL(fileURLWithPath: encodedPath)
        do {
            let data = try Data(contentsOf: fileURL)
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let response = URLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private final class WikiBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "WikiBundleSchemeHandler", code: 1))
            return
        }

        guard let resourceRoot = Bundle.main.resourceURL?.appendingPathComponent(LLMWikiPaths.frontendResourceDirectoryName) else {
            urlSchemeTask.didFailWithError(NSError(domain: "WikiBundleSchemeHandler", code: 2))
            return
        }

        let rawPath = url.path.isEmpty ? "/index.html" : url.path
        let relativePath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = resourceRoot.appendingPathComponent(relativePath.isEmpty ? "index.html" : relativePath)

        do {
            let data = try Data(contentsOf: fileURL)
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let response = URLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            appLog("[WikiHostView] bundle resource failed: \(fileURL.path) (\(error.localizedDescription))", level: .error)
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

final class WikiHostCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onPageLoaded: (() -> Void)?
    var onOpenWikiSupport: (() -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onRenderedContentState: ((Bool, String) -> Void)?
    weak var webView: WKWebView?

    private let dispatcher = LLMWikiHostCommandDispatcher.shared

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "ClawdHomeWikiConsole" {
            handleConsoleMessage(message.body)
            return
        }

        guard message.name == "ClawdHomeWikiBridge",
              let body = message.body as? [String: Any],
              let requestID = body["id"] as? String,
              let type = body["type"] as? String
        else { return }

        appLog("[WikiHostView] bridge request received: type=\(type) id=\(requestID)")
        Task { @MainActor in
            do {
                let result = try await handleMessage(type: type, body: body)
                complete(requestID: requestID, result: result)
            } catch {
                fail(requestID: requestID, message: error.localizedDescription)
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        recordDiagnostic("navigation started: \(webView.url?.absoluteString ?? "about:blank")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        recordDiagnostic("navigation committed")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recordDiagnostic("navigation finished")
        onPageLoaded?()
        inspectRenderedContent()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = "provisional navigation failed: \(error.localizedDescription)"
        appLog("[WikiHostView] \(message)", level: .warn)
        recordDiagnostic(message)
        onPageLoaded?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = "navigation failed: \(error.localizedDescription)"
        appLog("[WikiHostView] \(message)", level: .warn)
        recordDiagnostic(message)
        onPageLoaded?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let message = "web content process terminated"
        appLog("[WikiHostView] \(message)", level: .error)
        recordDiagnostic(message)
    }

    private func handleMessage(type: String, body: [String: Any]) async throws -> Any {
        switch type {
        case "invoke":
            let command = body["command"] as? String ?? ""
            let payload = body["payload"] ?? [:]
            return try await dispatcher.invoke(command: command, payload: payload)
        case "openDialog":
            let options = body["options"] as? [String: Any] ?? [:]
            return try await presentOpenDialog(options: options) ?? NSNull()
        case "storeLoad":
            let name = body["name"] as? String ?? "app-state.json"
            try LLMWikiAppStateStore.shared.loadStore(named: name)
            return NSNull()
        case "storeGet":
            let key = body["key"] as? String ?? ""
            return try LLMWikiAppStateStore.shared.getValue(forKey: key) ?? NSNull()
        case "storeSet":
            let key = body["key"] as? String ?? ""
            let value = body["value"] ?? NSNull()
            try LLMWikiAppStateStore.shared.setValue(value, forKey: key)
            return NSNull()
        case "openWikiSupport":
            onOpenWikiSupport?()
            return NSNull()
        default:
            throw NSError(
                domain: "WikiHostCoordinator",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported bridge request: \(type)"]
            )
        }
    }

    private func presentOpenDialog(options: [String: Any]) async throws -> Any? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = options["directory"] as? Bool ?? false
        panel.canChooseFiles = !(options["directory"] as? Bool ?? false)
        panel.allowsMultipleSelection = options["multiple"] as? Bool ?? false
        panel.title = options["title"] as? String ?? "Select"

        if let filters = options["filters"] as? [[String: Any]] {
            let extensions = filters
                .flatMap { ($0["extensions"] as? [String]) ?? [] }
                .filter { !$0.isEmpty && $0 != "*" }
            let contentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
            if !contentTypes.isEmpty {
                panel.allowedContentTypes = contentTypes
            }
        }

        let response = panel.runModal()
        guard response == .OK else { return nil }
        if panel.allowsMultipleSelection {
            return panel.urls.map(\.path)
        }
        return panel.url?.path
    }

    private func complete(requestID: String, result: Any) {
        guard let webView else { return }
        appLog("[WikiHostView] bridge request resolved: id=\(requestID)")
        let requestLiteral = javaScriptLiteral(requestID)
        let resultLiteral = javaScriptLiteral(result)
        let script = "window.ClawdHomeWiki && window.ClawdHomeWiki.__resolve(\(requestLiteral), \(resultLiteral));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func fail(requestID: String, message: String) {
        guard let webView else { return }
        appLog("[WikiHostView] bridge request failed: id=\(requestID) message=\(message)", level: .error)
        let requestLiteral = javaScriptLiteral(requestID)
        let errorLiteral = javaScriptLiteral(message)
        let script = "window.ClawdHomeWiki && window.ClawdHomeWiki.__reject(\(requestLiteral), \(errorLiteral));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func handleConsoleMessage(_ body: Any) {
        guard let payload = body as? [String: Any] else { return }
        let kind = payload["kind"] as? String ?? "console"
        let level = payload["level"] as? String ?? "log"
        let message = payload["message"] as? String ?? ""
        let summary = "[\(kind)] \(level): \(message)"
        switch level {
        case "error":
            appLog("[WikiHostView][JS] \(summary)", level: .error)
        case "warn":
            appLog("[WikiHostView][JS] \(summary)", level: .warn)
        default:
            appLog("[WikiHostView][JS] \(summary)")
        }
        recordDiagnostic(summary)
    }

    private func inspectRenderedContent(attempt: Int = 1) {
        guard let webView else { return }
        let script = """
        (() => {
          const root = document.getElementById('root');
          const rootText = (root?.innerText || '').trim();
          const bodyText = (document.body?.innerText || '').trim();
          return {
            readyState: document.readyState,
            title: document.title,
            rootChildCount: root?.childElementCount ?? 0,
            rootHtmlLength: root?.innerHTML?.length ?? 0,
            rootTextLength: rootText.length,
            bodyTextLength: bodyText.length
          };
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else { return }
            if let error {
                let message = "render inspection failed: \(error.localizedDescription)"
                self.recordDiagnostic(message)
                self.onRenderedContentState?(false, message)
                return
            }
            guard let payload = result as? [String: Any] else {
                let message = "render inspection returned no payload"
                self.recordDiagnostic(message)
                self.onRenderedContentState?(false, message)
                return
            }

            let rootChildCount = payload["rootChildCount"] as? Int ?? 0
            let rootHtmlLength = payload["rootHtmlLength"] as? Int ?? 0
            let rootTextLength = payload["rootTextLength"] as? Int ?? 0
            let bodyTextLength = payload["bodyTextLength"] as? Int ?? 0

            let hasRenderedContent = rootChildCount > 0 || rootHtmlLength > 0 || rootTextLength > 0 || bodyTextLength > 0
            let summary = "render inspection attempt \(attempt): rootChildCount=\(rootChildCount) rootHtmlLength=\(rootHtmlLength) rootTextLength=\(rootTextLength) bodyTextLength=\(bodyTextLength)"
            self.recordDiagnostic(summary)

            if hasRenderedContent {
                self.onRenderedContentState?(true, summary)
                return
            }

            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.inspectRenderedContent(attempt: attempt + 1)
                }
            } else {
                self.onRenderedContentState?(false, summary)
            }
        }
    }

    private func recordDiagnostic(_ message: String) {
        onDiagnostic?(message)
    }
}

private func javaScriptLiteral(_ value: Any) -> String {
    if value is NSNull { return "null" }
    if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
       let encoded = String(data: data, encoding: .utf8),
       encoded.count >= 2 {
        return String(encoded.dropFirst().dropLast())
    }
    return "null"
}

private func wikiBootstrapPayload() -> [String: Any] {
    [
        "projectPath": LLMWikiPaths.projectRoot,
        "projectName": LLMWikiPaths.sharedProjectName,
        "appStatePath": LLMWikiPaths.appStatePath(for: NSUserName()),
        "locale": Locale.current.identifier,
    ]
}

private func wikiBridgeBootstrapScript() -> String {
    let bootstrapJSON = javaScriptLiteral(wikiBootstrapPayload())
    return """
    (() => {
      const consoleBridge = window.webkit?.messageHandlers?.ClawdHomeWikiConsole;
      const postConsole = (payload) => {
        try {
          consoleBridge?.postMessage(payload);
        } catch (_) {}
      };
      const stringify = (value) => {
        if (typeof value === "string") return value;
        try { return JSON.stringify(value); } catch (_) { return String(value); }
      };
      ["log", "info", "warn", "error"].forEach((level) => {
        const original = console[level];
        console[level] = (...args) => {
          postConsole({
            kind: "console",
            level,
            message: args.map(stringify).join(" ")
          });
          return original.apply(console, args);
        };
      });
      window.addEventListener("error", (event) => {
        const target = event.target;
        if (target && target !== window) {
          postConsole({
            kind: "resource-error",
            level: "error",
            message: `${target.tagName || "resource"} failed: ${target.src || target.href || "unknown"}`
          });
          return;
        }
        postConsole({
          kind: "window-error",
          level: "error",
          message: `${event.message || "unknown error"} @ ${event.filename || "unknown"}:${event.lineno || 0}:${event.colno || 0}`
        });
      }, true);
      window.addEventListener("unhandledrejection", (event) => {
        postConsole({
          kind: "unhandledrejection",
          level: "error",
          message: stringify(event.reason)
        });
      });
      if (window.ClawdHomeWiki) {
        window.__CLAWDHOME_WIKI_BOOTSTRAP__ = \(bootstrapJSON);
        return;
      }
      let requestIndex = { value: 0 };
      const pending = new Map();
      function bridge(type, payload = {}) {
        return new Promise((resolve, reject) => {
          requestIndex.value += 1;
          const id = `wiki-${Date.now()}-${requestIndex.value}`;
          pending.set(id, { resolve, reject });
          window.webkit.messageHandlers.ClawdHomeWikiBridge.postMessage({ id, type, ...payload });
        });
      }
      window.__CLAWDHOME_WIKI_BOOTSTRAP__ = \(bootstrapJSON);
      window.ClawdHomeWiki = {
        invoke(command, payload = {}) { return bridge("invoke", { command, payload }); },
        openDialog(options = {}) { return bridge("openDialog", { options }); },
        storeLoad(name) { return bridge("storeLoad", { name }); },
        storeGet(key) { return bridge("storeGet", { key }); },
        storeSet(key, value) { return bridge("storeSet", { key, value }); },
        convertFileSrc(path) { return `clawdhome-file://local?path=${encodeURIComponent(path)}`; },
        openWikiSupport() { return bridge("openWikiSupport"); },
        __resolve(id, value) {
          const entry = pending.get(id);
          if (!entry) return;
          pending.delete(id);
          entry.resolve(value);
        },
        __reject(id, error) {
          const entry = pending.get(id);
          if (!entry) return;
          pending.delete(id);
          entry.reject(new Error(typeof error === "string" ? error : "Host bridge error"));
        },
      };
    })();
    """
}

private func makeWikiHostConfiguration(coordinator: WikiHostCoordinator) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    let userScript = WKUserScript(
        source: wikiBridgeBootstrapScript(),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )
    configuration.userContentController.addUserScript(userScript)
    configuration.userContentController.add(coordinator, name: "ClawdHomeWikiBridge")
    configuration.userContentController.add(coordinator, name: "ClawdHomeWikiConsole")
    configuration.setURLSchemeHandler(WikiFileSchemeHandler(), forURLScheme: "clawdhome-file")
    configuration.setURLSchemeHandler(WikiBundleSchemeHandler(), forURLScheme: "clawdhome-wiki")
    return configuration
}

private func embeddedWikiIndexURL() -> URL? {
    URL(string: "clawdhome-wiki://app/index.html")
}

final class WikiHostWebViewCache {
    static let shared = WikiHostWebViewCache()
    private init() {}

    private(set) var webView: WKWebView?
    private(set) var coordinator: WikiHostCoordinator?

    @MainActor
    func ensureCoordinator() -> WikiHostCoordinator {
        if let coordinator {
            return coordinator
        }
        let coordinator = WikiHostCoordinator()
        self.coordinator = coordinator
        return coordinator
    }

    @MainActor
    func preloadIfNeeded() {
        guard webView == nil else { return }
        let coordinator = ensureCoordinator()
        let configuration = makeWikiHostConfiguration(coordinator: coordinator)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.setValue(false, forKey: "drawsBackground")

        coordinator.webView = webView
        self.webView = webView
    }
}

private struct WikiEmbeddedWebView: NSViewRepresentable {
    let coordinator: WikiHostCoordinator

    func makeCoordinator() -> WikiHostCoordinator { coordinator }

    func makeNSView(context: Context) -> WKWebView {
        if let cached = WikiHostWebViewCache.shared.webView {
            cached.navigationDelegate = context.coordinator
            context.coordinator.webView = cached
            return cached
        }

        let configuration = makeWikiHostConfiguration(coordinator: context.coordinator)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        if let url = embeddedWikiIndexURL() {
            webView.load(URLRequest(url: url))
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.webView = nsView
    }
}

struct WikiHostView: View {
    let onOpenWikiSupport: () -> Void

    @State private var loadState: WikiHostLoadState = .preparing
    @State private var refreshToken = UUID()
    @State private var latestDiagnostic = "No diagnostics yet."
    @State private var isPageLoaded: Bool = {
        if let webView = WikiHostWebViewCache.shared.webView,
           !webView.isLoading,
           webView.url != nil {
            return true
        }
        return false
    }()

    private let runtimeManager = LLMWikiRuntimeManager.shared
    private let storeService = LLMWikiStoreService()

    private var coordinator: WikiHostCoordinator {
        WikiHostWebViewCache.shared.ensureCoordinator()
    }

    var body: some View {
        ZStack {
            if !isBlocked {
                WikiEmbeddedWebView(coordinator: coordinator)
                    .opacity(loadState == .ready && isPageLoaded ? 1 : 0)
                    .animation(.easeIn(duration: 0.2), value: isPageLoaded)
            }

            switch loadState {
            case .preparing:
                ProgressView("Preparing Wiki…")
                    .controlSize(.regular)
            case .blocked(let message):
                blockedState(message: message)
            case .ready:
                if !isPageLoaded {
                    ProgressView("Loading Wiki…")
                } else if let diagnosticMessage = blankPageDiagnosticMessage {
                    blockedState(message: diagnosticMessage)
                }
            }
        }
        .navigationTitle("Wiki")
        .task(id: refreshToken) {
            await prepareWiki()
        }
        .onAppear {
            coordinator.onPageLoaded = {
                withAnimation {
                    self.isPageLoaded = true
                }
            }
            coordinator.onDiagnostic = { message in
                self.latestDiagnostic = message
            }
            coordinator.onRenderedContentState = { hasContent, message in
                self.latestDiagnostic = message
                if !hasContent, self.loadState == .ready {
                    self.loadState = .blocked("Wiki frontend loaded but rendered no content. Latest diagnostic: \(message)")
                }
            }
            coordinator.onOpenWikiSupport = onOpenWikiSupport
        }
        .onReceive(NotificationCenter.default.publisher(for: .llmWikiConfigDidChange)) { _ in
            isPageLoaded = false
            latestDiagnostic = "Reloading Wiki after config update..."
            if let url = embeddedWikiIndexURL() {
                coordinator.webView?.load(URLRequest(url: url))
            } else {
                coordinator.webView?.reload()
            }
        }
    }

    private var isBlocked: Bool {
        if case .blocked = loadState { return true }
        return false
    }

    private var blankPageDiagnosticMessage: String? {
        guard loadState == .ready, isPageLoaded else { return nil }
        return nil
    }

    @ViewBuilder
    private func blockedState(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("Wiki unavailable")
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button("Retry") {
                    isPageLoaded = false
                    loadState = .preparing
                    refreshToken = UUID()
                }
                Button("Open Wiki Support") {
                    onOpenWikiSupport()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func prepareWiki() async {
        do {
            guard let resourceURL = Bundle.main.url(
                forResource: "index",
                withExtension: "html",
                subdirectory: LLMWikiPaths.frontendResourceDirectoryName
            ) else {
                loadState = .blocked("Embedded Wiki frontend assets are missing from the app bundle.")
                return
            }

            let requiredPaths = [
                LLMWikiPaths.projectRoot,
                "\(LLMWikiPaths.projectRoot)/wiki",
                "\(LLMWikiPaths.projectRoot)/raw/sources",
                LLMWikiPaths.shrimpsSourcesRoot,
            ]
            for path in requiredPaths where !FileManager.default.fileExists(atPath: path) {
                loadState = .blocked("Shared Wiki project is incomplete at \(path). Repair it from Notes before reopening Wiki.")
                return
            }

            try LLMWikiAppStateStore.shared.loadStore(named: "app-state.json")
            try storeService.ensureProjectBinding(projectPath: LLMWikiPaths.projectRoot)
            try await runtimeManager.ensureRunning()
            appLog("[WikiHostView] shared runtime and project binding ready")

            if WikiHostWebViewCache.shared.webView == nil {
                WikiHostWebViewCache.shared.preloadIfNeeded()
                appLog("[WikiHostView] preloaded Wiki web view cache")
            }

            if let currentURL = WikiHostWebViewCache.shared.webView?.url?.absoluteString {
                appLog("[WikiHostView] current web view URL: \(currentURL)")
            }

            if WikiHostWebViewCache.shared.webView?.url?.scheme != "clawdhome-wiki",
               let url = embeddedWikiIndexURL() {
                WikiHostWebViewCache.shared.webView?.load(URLRequest(url: url))
                appLog("[WikiHostView] loading embedded frontend via custom scheme: \(url.absoluteString)")
            }

            loadState = .ready
        } catch {
            loadState = .blocked(error.localizedDescription)
        }
    }
}
