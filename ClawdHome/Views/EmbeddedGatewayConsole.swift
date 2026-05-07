// ClawdHome/Views/EmbeddedGatewayConsole.swift

import AppKit
import SwiftUI
import WebKit

struct EmbeddedGatewayConsoleView: NSViewRepresentable {
    let url: URL
    @ObservedObject var store: EmbeddedGatewayConsoleStore

    func makeCoordinator() -> EmbeddedGatewayConsoleCoordinator {
        store.coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        let webView = store.resolveWebView()
        attach(webView, to: container)
        store.loadIfNeeded(url)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let webView = store.resolveWebView()
        attach(webView, to: nsView)
        store.loadIfNeeded(url)
    }

    private func attach(_ webView: WKWebView, to container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

extension EmbeddedGatewayConsoleCoordinator: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "fileInputAccept" else { return }
        guard let body = message.body as? [String: Any],
              let accept = body["accept"] as? String else { return }
        pendingFileInputAccept = accept
    }
}

extension WKUserScript {
    static let fileInputAcceptCapture = WKUserScript(
        source: """
        (() => {
          const sendAccept = (target) => {
            const input = target && target.closest ? target.closest('input[type="file"]') : null;
            if (!input) return;
            window.webkit.messageHandlers.fileInputAccept.postMessage({ accept: input.accept || '' });
          };
          document.addEventListener('click', (event) => sendAccept(event.target), true);
          document.addEventListener('keydown', (event) => {
            if (event.key === 'Enter' || event.key === ' ') sendAccept(event.target);
          }, true);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )

    static let controlUIBootstrapReset = WKUserScript(
        source: """
        (() => {
          try {
            if (!window.location || !window.location.hash) return;
            const hash = window.location.hash || "";
            if (!hash.includes("token=")) return;
            // 防止同一 origin（按端口区分）上的旧控制台设置污染新 token 引导。
            try { sessionStorage.removeItem("openclaw.control.settings.v1"); } catch (_) {}
            try { localStorage.removeItem("openclaw.control.settings.v1"); } catch (_) {}
            try { sessionStorage.removeItem("openclaw.control.settings"); } catch (_) {}
            try { localStorage.removeItem("openclaw.control.settings"); } catch (_) {}
          } catch (_) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )
}
