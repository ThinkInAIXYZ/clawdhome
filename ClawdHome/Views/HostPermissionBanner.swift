import SwiftUI
import AppKit

struct HostPermissionPromptRequest: Identifiable, Equatable {
    let id = UUID()
    let actionLabel: String
    let missingPermissions: [HostPermissionRequirement]
}

extension View {
    func hostPermissionPrompt(
        _ request: Binding<HostPermissionPromptRequest?>
    ) -> some View {
        modifier(HostPermissionPromptModifier(request: request))
    }
}

private struct HostPermissionPromptModifier: ViewModifier {
    @Environment(HostPermissionCenter.self) private var permissionCenter
    @Binding var request: HostPermissionPromptRequest?

    func body(content: Content) -> some View {
        content.sheet(item: $request) { req in
            HostPermissionPromptView(request: req) {
                request = nil
            }
        }
    }
}

private struct HostPermissionPromptView: View {
    @Environment(HostPermissionCenter.self) private var permissionCenter
    let request: HostPermissionPromptRequest
    let onDismiss: () -> Void

    @State private var successTransition = false
    @State private var successScale: CGFloat = 0.1
    @State private var timerActive = true
    
    // 轮询 Timer，每 1.0 秒触发一次
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // 背景毛玻璃质感
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .ignoresSafeArea()
            
            if successTransition {
                // 成功态炫酷过渡
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.green)
                        .scaleEffect(successScale)
                        .shadow(color: .green.opacity(0.3), radius: 10, y: 5)
                    
                    Text(L10n.k("host_permission.prompt.custom.success_toast", fallback: "授权成功！正在继续..."))
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                .transition(.opacity.combined(with: .scale))
                .onAppear {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.5)) {
                        successScale = 1.0
                    }
                    // 成功后延迟 0.8s 自动关闭
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        onDismiss()
                    }
                }
            } else {
                // 主引导视图
                VStack(spacing: 0) {
                    // 仿 macOS 独立窗口顶栏
                    HStack {
                        HStack(spacing: 8) {
                            Circle().fill(Color.red.opacity(0.8)).frame(width: 12, height: 12)
                            Circle().fill(Color.yellow.opacity(0.8)).frame(width: 12, height: 12)
                            Circle().fill(Color.green.opacity(0.8)).frame(width: 12, height: 12)
                        }
                        Spacer()
                        Text(L10n.k("host_permission.prompt.custom.title", fallback: "系统权限授权引导"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        // 占位以平衡小红点
                        HStack(spacing: 8) {
                            Circle().fill(Color.clear).frame(width: 12, height: 12)
                            Circle().fill(Color.clear).frame(width: 12, height: 12)
                            Circle().fill(Color.clear).frame(width: 12, height: 12)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    
                    Divider()
                    
                    VStack(spacing: 24) {
                        // 头部提示词
                        VStack(spacing: 8) {
                            Text(L10n.k("host_permission.banner.title", fallback: "需要系统权限授权"))
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(.primary)
                            
                            Text(L10n.f("host_permission.prompt.message", fallback: "执行“%@”前，需要先授权：%@。你也可以稍后去设置里手动授权，完成后再重试。", request.actionLabel, request.missingPermissionsText))
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }
                        .padding(.top, 16)
                        
                        // 步骤展示区
                        VStack(spacing: 20) {
                            // 步骤 1：打开设置
                            StepCardView(stepNum: 1, title: L10n.k("host_permission.prompt.custom.step1.title", fallback: "1. 点击下方按钮打开系统偏好设置"), description: L10n.k("host_permission.prompt.custom.step1.desc", fallback: "点击按钮将自动为您直达对应的系统隐私设置页面")) {
                                Button(action: {
                                    permissionCenter.openSettings(for: request.missingPermissions)
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.up.forward.app")
                                        Text(L10n.k("host_permission.prompt.custom.step1.button", fallback: "打开系统偏好设置"))
                                    }
                                    .frame(height: 32)
                                    .padding(.horizontal, 16)
                                    .background(Color.accentColor)
                                    .foregroundStyle(.white)
                                    .cornerRadius(16)
                                }
                                .buttonStyle(.plain)
                            }
                            
                            // 步骤 2：开启权限
                            StepCardView(stepNum: 2, title: L10n.k("host_permission.prompt.custom.step2.title", fallback: "2. 开启对应的应用权限"), description: request.missingPermissions.contains(.accessibility)
                                         ? L10n.k("host_permission.prompt.custom.accessibility.step2", fallback: "将下方 ClawdHome 图标直接拖拽到系统偏好设置右侧「辅助功能」列表中")
                                         : L10n.k("host_permission.prompt.custom.automation.step2", fallback: "在系统偏好设置右侧「自动化」列表中展开 ClawdHome 并勾选「Google Chrome」")) {
                                if request.missingPermissions.contains(.accessibility) {
                                    DragAppIconView()
                                } else {
                                    AutomationGuideView()
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    
                    Spacer()
                    
                    HStack {
                        Spacer()
                        Text(L10n.k("host_permission.prompt.custom.help.contact", fallback: "问题没有解决？联系我们"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .underline()
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    
                    Divider()
                    
                    // 页脚控制按钮
                    HStack(spacing: 12) {
                        Button(L10n.k("common.action.cancel", fallback: "取消")) {
                            onDismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        
                        Spacer()
                        
                        Button(L10n.k("host_permission.prompt.custom.action.authorized", fallback: "我已完成授权")) {
                            permissionCenter.refresh()
                            if permissionCenter.isSatisfied(request.missingPermissions) {
                                withAnimation {
                                    successTransition = true
                                }
                            } else {
                                // 权限仍未获得时，系统发声或振动提示
                                NSSound.beep()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
        }
        .frame(width: 560, height: 600)
        .onReceive(timer) { _ in
            guard timerActive else { return }
            permissionCenter.refresh()
            // 如果缺失列表为空，说明授权成功
            if permissionCenter.isSatisfied(request.missingPermissions) {
                timerActive = false
                withAnimation {
                    successTransition = true
                }
            }
        }
    }
}

// MARK: - 步骤展示组件
private struct StepCardView<Content: View>: View {
    let stepNum: Int
    let title: String
    let description: String
    let content: Content
    
    init(stepNum: Int, title: String, description: String, @ViewBuilder content: () -> Content) {
        self.stepNum = stepNum
        self.title = title
        self.description = description
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
            
            HStack {
                Spacer()
                content
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - 拖动 App 图标组件
struct DragAppIconView: View {
    @State private var isHovering = false
    @State private var dragPulse = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // 呼吸效果的闪烁背景边框
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 10, dash: [6, 4], dashPhase: dragPulse ? 20 : 0)
                    )
                    .frame(width: 110, height: 110)
                    .background(Color.secondary.opacity(0.04).cornerRadius(16))
                
                // App 图标
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(isHovering ? 0.3 : 0.15), radius: isHovering ? 10 : 5, y: isHovering ? 4 : 2)
                    .scaleEffect(isHovering ? 1.06 : 1.0)
                    .onDrag {
                        let fileURL = Bundle.main.bundleURL
                        return NSItemProvider(contentsOf: fileURL) ?? NSItemProvider()
                    }
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            isHovering = hovering
                        }
                    }
            }
            .onAppear {
                withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                    dragPulse = true
                }
            }
            
            Text(L10n.k("host_permission.prompt.custom.step2.drag_hint", fallback: "按住上方图标拖拽至系统设置窗口中"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 自动化权限引导示意
struct AutomationGuideView: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .cornerRadius(10)
                    .shadow(radius: 2)
                
                Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                
                Image(systemName: "safari.fill") // 代表浏览器
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .background(Color.blue.opacity(0.1).cornerRadius(10))
            }
            .padding(.vertical, 6)
            
            Text(L10n.k("host_permission.prompt.custom.automation.step2", fallback: "在系统偏好设置右侧「自动化」列表中展开 ClawdHome 并勾选「Google Chrome」"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(width: 320, height: 110)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - 毛玻璃组件
private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

private extension HostPermissionPromptRequest {
    var missingPermissionsText: String {
        let separator = Self.isChineseUI ? "、" : ", "
        return missingPermissions
            .map(\.displayName)
            .joined(separator: separator)
    }

    static var isChineseUI: Bool {
        let selected = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        switch AppLanguage(rawValue: selected) ?? .system {
        case .chineseSimplified:
            return true
        case .english:
            return false
        case .system:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        }
    }
}

private extension HostPermissionRequirement {
    var displayName: String {
        switch self {
        case .accessibility:
            return L10n.k("settings.permissions.accessibility", fallback: "辅助功能")
        case .chromeAutomation:
            return L10n.k("settings.permissions.chrome_automation", fallback: "Chrome 自动化")
        }
    }
}

// 兼容现有工程文件引用；首页常驻权限浮层已停用。
struct HostPermissionBanner: View {
    var body: some View {
        EmptyView()
    }
}
