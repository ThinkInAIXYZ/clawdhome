// ClawdHome/Views/WizardComponents.swift
// 初始化向导可复用 UI 组件

import SwiftUI

struct WizardInputSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
    }
}

struct WizardPanelCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            )
    }
}

struct WizardWindowTitleBinder: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(window: nsView.window)
        }
    }

    private func apply(window: NSWindow?) {
        guard let window else { return }
        if window.title != title {
            window.title = title
        }
    }
}

extension View {
    func wizardInputSurface() -> some View {
        modifier(WizardInputSurfaceModifier())
    }

    func wizardPanelCard() -> some View {
        modifier(WizardPanelCardModifier())
    }
}

struct GatewayActivationCard: View {
    let progress: Double
    let isAnimating: Bool
    let isShrimpLifted: Bool

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.accentColor.opacity(isAnimating ? 0.22 : 0.12),
                                Color.accentColor.opacity(0.03),
                                .clear
                            ],
                            center: .center,
                            startRadius: 18,
                            endRadius: 96
                        )
                    )
                    .frame(width: 196, height: 196)
                    .blur(radius: 4)
                    .opacity(isAnimating ? 1 : 0.7)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.98),
                                Color.accentColor.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    )
                    .shadow(color: Color.accentColor.opacity(0.14), radius: 28, x: 0, y: 14)
                    .frame(width: 160, height: 160)

                Text("🦞")
                    .font(.system(size: 68))
                    .offset(y: isShrimpLifted ? -5 : 5)
                    .scaleEffect(isShrimpLifted ? 1.03 : 0.98)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                Text(L10n.k("views.user_init_wizard_view.initialization_completed", fallback: "配置完成"))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)

                Text(L10n.k("views.user_init_wizard_view.done_overview", fallback: "正在启动 OpenClaw Gateway…"))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 8) {
                    ProgressView(value: progress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                    Text(L10n.k("views.user_init_wizard_view.gateway_activation_hint", fallback: "首次启动可能需要一点时间，请保持窗口开启。"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct EnvironmentSetupWaitingCard: View {
    let title: String
    let subtitle: String
    let rotatingStatus: String
    let isSceneLifted: Bool
    let isToolRaised: Bool
    let isGlowActive: Bool

    var body: some View {
        let cardWidth: CGFloat = 420
        let cardHeight: CGFloat = 220

        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(isGlowActive ? 0.16 : 0.10),
                                Color.blue.opacity(0.05),
                                Color.white.opacity(0.94)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: cardWidth, height: cardHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.75), lineWidth: 1)
                    )
                    .shadow(color: Color.accentColor.opacity(0.10), radius: 28, x: 0, y: 18)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.accentColor.opacity(isGlowActive ? 0.22 : 0.14),
                                Color.accentColor.opacity(0.04),
                                .clear
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 110
                        )
                    )
                    .frame(width: 220, height: 220)
                    .blur(radius: 12)
                    .offset(y: -18)

                VStack(spacing: 12) {
                    HStack(spacing: 18) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.92))
                                .frame(width: 112, height: 88)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
                                )

                            VStack(spacing: 8) {
                                Image(systemName: "house.fill")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(Color.accentColor.opacity(0.90))
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.14))
                                    .frame(width: 54, height: 8)
                            }
                        }

                        ZStack {
                            Text("🦞")
                                .font(.system(size: 48))
                                .offset(x: -2, y: isSceneLifted ? -6 : 6)
                                .scaleEffect(isSceneLifted ? 1.03 : 0.98)

                            Image(systemName: "hammer.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.orange.opacity(0.95))
                                .rotationEffect(.degrees(isToolRaised ? -28 : 14))
                                .offset(x: 30, y: isToolRaised ? -28 : -8)
                        }
                        .frame(width: 98, height: 98)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.accentColor)
                        Text(rotatingStatus)
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                }
            }

        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}
