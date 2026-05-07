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
        if message.name == "fileInputAccept" {
            guard let body = message.body as? [String: Any],
                  let accept = body["accept"] as? String else { return }
            pendingFileInputAccept = accept
            return
        }

        if message.name == "promptMemory" {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            let text = body["text"] as? String ?? ""
            switch action {
            case "open":
                onPromptMemoryRequest?(text)
            case "input":
                onPromptInputChanged?(text)
            default:
                break
            }
        }
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

    static let promptMemoryBridge = WKUserScript(
        source: """
        (() => {
          if (window.__clawdPromptMemoryInstalled) return;
          window.__clawdPromptMemoryInstalled = true;

          var lastEditable = null;
          var lastTabAt = 0;
          var pendingInputTimer = null;

          const isEditable = (el) => {
            if (!el) return false;
            if (el.isContentEditable) return true;
            const tag = (el.tagName || '').toLowerCase();
            if (tag === 'textarea') return true;
            if (tag !== 'input') return false;
            const type = (el.getAttribute('type') || 'text').toLowerCase();
            return ['text', 'search', 'url', 'email', 'tel', 'password'].includes(type);
          };

          const editableFrom = (target) => {
            if (!target) return null;
            if (isEditable(target)) return target;
            return target.closest ? target.closest('textarea,input,[contenteditable="true"],[contenteditable=""]') : null;
          };

          const resolveEditable = () => {
            if (isEditable(document.activeElement)) return document.activeElement;
            if (isEditable(lastEditable)) return lastEditable;
            const candidates = Array.from(document.querySelectorAll('textarea, input[type="text"], input:not([type]), [contenteditable="true"], [contenteditable=""]'));
            return candidates.find((node) => {
              const style = window.getComputedStyle(node);
              return style.display !== 'none' && style.visibility !== 'hidden' && !node.disabled && !node.readOnly;
            }) || null;
          };

          const getText = (el) => {
            if (!el) return '';
            if (el.isContentEditable) return el.innerText || el.textContent || '';
            return typeof el.value === 'string' ? el.value : '';
          };

          const setText = (el, text) => {
            if (!el) return false;
            el.focus();
            if (el.isContentEditable) {
              el.innerText = text;
            } else {
              el.value = text;
            }
            el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
          };

          const post = (body) => {
            try { window.webkit.messageHandlers.promptMemory.postMessage(body); } catch (_) {}
          };

          const remember = (el) => {
            if (isEditable(el)) lastEditable = el;
          };

          const sendInput = (el) => {
            const text = getText(el);
            window.clearTimeout(pendingInputTimer);
            pendingInputTimer = window.setTimeout(() => post({ action: 'input', text }), 450);
          };

          document.addEventListener('focusin', (event) => remember(editableFrom(event.target)), true);
          document.addEventListener('input', (event) => {
            const el = editableFrom(event.target);
            if (!el) return;
            remember(el);
            sendInput(el);
          }, true);
          document.addEventListener('keydown', (event) => {
            const el = editableFrom(event.target);
            if (!el) return;
            remember(el);
            if (event.key !== 'Tab') return;
            const now = Date.now();
            if (now - lastTabAt < 1500) {
              event.preventDefault();
              event.stopPropagation();
              post({ action: 'open', text: getText(el) });
            }
            lastTabAt = now;
          }, true);

          window.__clawdPromptMemory = {
            insert(payload) {
              const el = resolveEditable();
              if (!el) return false;
              const current = getText(el);
              const incoming = payload && payload.text ? String(payload.text) : '';
              const mode = payload && payload.mode === 'replace' ? 'replace' : 'append';
              const next = mode === 'replace'
                ? incoming
                : (current.trim().length ? current + '\\n\\n' + incoming : incoming);
              return setText(el, next);
            },
            currentText() {
              const el = resolveEditable();
              return getText(el);
            }
          };
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )
}
