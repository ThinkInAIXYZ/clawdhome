// ClawdHome/Views/DesignSystem.swift
// ClawdHome 统一的高质感设计系统组件与修饰器

import SwiftUI

public struct DesignSystem {
    
    // MARK: - 情感渐变主题
    public enum GradientTheme {
        case blue       // 语音/转译：深邃蓝紫
        case purple     // 语音克隆：科技粉紫
        case emerald    // 文本翻译：畅通青绿
        case orange     // 图像描述：探索橘红
        case teal       // 文档摘要：逻辑海洋
        case slate      // 规划中：沉静冷灰
        
        public var colors: [Color] {
            switch self {
            case .blue:
                return [Color.blue, Color(nsColor: .systemPurple)]
            case .purple:
                return [Color(nsColor: .systemPurple), Color(nsColor: .systemPink)]
            case .emerald:
                return [Color(nsColor: .systemGreen), Color(nsColor: .systemTeal)]
            case .orange:
                return [Color(nsColor: .systemOrange), Color(nsColor: .systemRed)]
            case .teal:
                return [Color(nsColor: .systemTeal), Color.blue]
            case .slate:
                return [Color.secondary.opacity(0.3), Color.secondary.opacity(0.15)]
            }
        }
        
        public var mainColor: Color {
            colors.first ?? .blue
        }
        
        public var gradient: LinearGradient {
            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        
        public func dynamicGradient(isHovered: Bool) -> LinearGradient {
            if isHovered && self != .slate {
                // 鼠标悬停时渐变略微倾斜/位移以产生流动感
                return LinearGradient(
                    colors: colors.map { $0.opacity(0.95) },
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            return gradient
        }
    }
    
    // MARK: - 徽章状态样式
    public enum BadgeStyle {
        case ready          // 已就绪 (绿色呼吸发光点)
        case inDevelopment  // 研发中 (紫色科技发光点)
        case planned        // 规划中 (灰色沉静发光点)
        
        public var text: String {
            switch self {
            case .ready:
                return L10n.k("auto.ailab_view.available", fallback: "已就绪")
            case .inDevelopment:
                return L10n.k("auto.ailab_view.coming_soon", fallback: "研发中")
            case .planned:
                return L10n.k("auto.ailab_view.planned", fallback: "规划中")
            }
        }
        
        public var color: Color {
            switch self {
            case .ready: return .green
            case .inDevelopment: return .purple
            case .planned: return .secondary
            }
        }
    }
}

// MARK: - 状态呼吸徽章组件
public struct PremiumStatusBadge: View {
    let style: DesignSystem.BadgeStyle
    @State private var isBreathing = false
    
    public init(style: DesignSystem.BadgeStyle) {
        self.style = style
    }
    
    public var body: some View {
        HStack(spacing: 5) {
            // 呼吸发光圆点
            ZStack {
                Circle()
                    .fill(style.color)
                    .frame(width: 6, height: 6)
                
                if style == .ready || style == .inDevelopment {
                    Circle()
                        .stroke(style.color, lineWidth: 2)
                        .scaleEffect(isBreathing ? 2.2 : 1.0)
                        .opacity(isBreathing ? 0.0 : 0.6)
                        .frame(width: 6, height: 6)
                }
            }
            .onAppear {
                if style == .ready || style == .inDevelopment {
                    withAnimation(
                        .easeInOut(duration: 1.8)
                        .repeatForever(autoreverses: false)
                    ) {
                        isBreathing = true
                    }
                }
            }
            
            Text(style.text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(style.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(style.color.opacity(0.12))
        )
        .overlay(
            Capsule()
                .stroke(style.color.opacity(0.24), lineWidth: 0.7)
        )
    }
}

// MARK: - 玻璃拟态悬浮卡片修饰器
private struct PremiumCardModifier: ViewModifier {
    let theme: DesignSystem.GradientTheme
    let isAvailable: Bool
    let action: (() -> Void)?
    
    @State private var isHovered = false
    @Environment(\.colorScheme) var colorScheme
    
    func body(content: Content) -> some View {
        let cardBody = content
            .padding(18)
            .background(
                ZStack {
                    // 1. 采用苹果系统级自适应卡片底色 (Light Mode 下为高对比纯白，Dark Mode 下为优雅碳灰，提供极佳的视觉可读性)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .textBackgroundColor))
                    
                    // 2. 仅在可用时，hover 产生极其微妙的卡片表面渐变晕染
                    if isAvailable {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        theme.mainColor.opacity(isHovered ? 0.06 : 0.015),
                                        .clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
            )
            .overlay(
                // 3. 极细微高反光立体描边，亮色下高透透亮且轮廓鲜明，暗色下微透轻奢
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.12 : 0.80),
                                Color.secondary.opacity(colorScheme == .dark ? 0.04 : 0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(
                // 4. 精心调校的自适应柔和散发阴影，避免脏色，hover 时映射出淡彩发光阴影，亮色模式下更加立体分明
                color: isHovered && isAvailable
                    ? theme.mainColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
                    : Color.black.opacity(colorScheme == .dark ? 0.24 : 0.06),
                radius: isHovered && isAvailable ? 12 : 6,
                x: 0,
                y: isHovered && isAvailable ? 6 : 3
            )
            .scaleEffect(isHovered && isAvailable ? 1.025 : 1.0)
            .onHover { hovering in
                guard isAvailable else { return }
                withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) {
                    isHovered = hovering
                }
            }
        
        if let action = action, isAvailable {
            Button(action: action) {
                cardBody
            }
            .buttonStyle(.plain)
        } else {
            cardBody
        }
    }
}

// MARK: - 统一视图扩展
extension View {
    /// 转换为极具质感的玻璃拟态悬浮卡片
    /// - Parameters:
    ///   - theme: 情感渐变主题
    ///   - isAvailable: 是否可用状态
    ///   - action: 点击卡片触发的动作（若为 nil 则仅用于纯展示）
    public func premiumCard(
        theme: DesignSystem.GradientTheme,
        isAvailable: Bool = true,
        action: (() -> Void)? = nil
    ) -> some View {
        self.modifier(PremiumCardModifier(theme: theme, isAvailable: isAvailable, action: action))
    }
}
