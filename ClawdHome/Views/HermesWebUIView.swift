// ClawdHome/Views/HermesWebUIView.swift
// 完美的 WKWebView SwiftUI 封装，支持暗黑模式自适应与微秒级启动延迟自动重试

import AppKit
import SwiftUI
import WebKit

struct HermesWebUIView: View {
    let url: URL

    var body: some View {
        HermesWKWebViewRepresentable(url: url)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct HermesWKWebViewRepresentable: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 允许跨域及本地文件读取
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        
        // 优化深色模式防闪烁
        webView.setValue(false, forKey: "drawsBackground") // 透明背景以应用外层 Swift 颜色
        
        context.coordinator.webView = webView
        context.coordinator.loadURL()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 仅在端口变化导致 URL 切换时重载，避免窗口焦点切换时重建 WebView。
        if context.coordinator.currentURL != url {
            context.coordinator.currentURL = url
            context.coordinator.loadURL()
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        enum PopupNavigationAction: Equatable {
            case ignore
            case openExternally(URL)
        }

        var currentURL: URL
        weak var webView: WKWebView?
        private var retryCount = 0
        private let maxRetries = 5

        init(url: URL) {
            self.currentURL = url
        }

        func loadURL() {
            guard let webView else { return }
            let request = URLRequest(url: currentURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10.0)
            webView.load(request)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            retryCount = 0 // 成功后重置重试计数
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleLoadFailure(error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleLoadFailure(error: error)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            switch popupNavigationAction(for: navigationAction) {
            case .ignore:
                break
            case .openExternally(let requestURL):
                NSWorkspace.shared.open(requestURL)
            }
            return nil
        }

        func popupNavigationAction(for navigationAction: WKNavigationAction) -> PopupNavigationAction {
            Self.popupNavigationAction(
                targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame,
                requestURL: navigationAction.request.url
            )
        }

        static func popupNavigationAction(targetFrameIsMainFrame: Bool?, requestURL: URL?) -> PopupNavigationAction {
            guard targetFrameIsMainFrame != true, let requestURL else { return .ignore }
            return .openExternally(requestURL)
        }

        private func handleLoadFailure(error: Error) {
            let nsError = error as NSError
            // NSURLErrorCannotConnectToHost (-1004) 表示服务还在启动中
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotConnectToHost {
                if retryCount < maxRetries {
                    retryCount += 1
                    let delay = 0.5 * Double(retryCount)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.loadURL()
                    }
                }
            }
        }
    }
}
