// ClawdHome/Views/PrivacyFilterView.swift
// 本地内容脱敏交互主视图 - 适配 ClawdHome 极致视觉体系

import SwiftUI
import UniformTypeIdentifiers

struct PrivacyFilterView: View {
    @Environment(\.colorScheme) private var colorScheme
    let onBack: () -> Void

    @State private var inputText = ""
    @State private var spans: [PrivacySpan] = []
    @State private var redactedText = ""
    @State private var llmOutputText = ""
    @State private var restoredLLMText = ""
    @State private var hasAnalyzedCurrentInput = false
    @State private var viewMode = 0 // 0: 左右对比, 1: 高亮标注, 2: 变更列表
    @State private var selectedEngine: FilterEngineType = .semanticLocal
    @State private var selectedSemanticModel: PrivacySemanticModel = .openAIPrivacyFilterQ4
    @State private var engine = PrivacyFilterEngine()
    @State private var hasRunUISmoke = false

    // Toast 状态
    @State private var toastMessage = ""
    @State private var showToast = false

    // 神经网络扫描动画状态
    @State private var isAnalyzing = false
    @State private var scanProgress: CGFloat = 0.0

    // 内置样例模板
    private struct SampleTemplate {
        let name: String
        let icon: String
        let content: String
    }

    private let samples = [
        SampleTemplate(
            name: L10n.k("auto.privacy_filter.sample_contract", fallback: "中文商用合同"),
            icon: "doc.text.fill",
            content: """
            房屋租赁合同

            甲方（出租方）：张伟（身份证号：110105198806012345，电话：13912345678），居住于北京市朝阳区建国门外大街2号。
            乙方（承租方）：李娜（身份证号：310104199211056789，电话：18688889999），居住于上海市徐汇区淮海中路888号。

            双方约定，房屋租金支付至乙方指定的招商银行账户：6225880123456789，户名：李娜。
            如有合同条款争议，可发送邮件至官方邮箱 property.mgmt@agency.com 协商处理。
            特此立合同。
            """
        ),
        SampleTemplate(
            name: L10n.k("auto.privacy_filter.sample_logs", fallback: "开发配置日志"),
            icon: "terminal.fill",
            content: """
            2026-06-16 10:15:30.412 [ERROR] Database connection failed for user 'admin_db' to PostgreSQL.
            Connection string: postgresql://admin_db:mY_sUpEr_pAsSwOrD_123@192.168.1.50:5432/clawdhome_prod

            2026-06-16 10:15:31.002 [WARN] Invalid API Credentials.
            Authorization Bearer header detected: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VySWQiOiJ1c3JfMDEyMzQ1Njc4OSJ9
            Failed to query OpenAI models endpoint. Please verify your API Key: sk-proj-a1B2c3D4e5F6g7H8i9J0k1L2M3N4O5P6q7R8s9T0u1V2w3X4y5Z
            Client secret: sec_dev_clawdhome_v1.
            """
        ),
        SampleTemplate(
            name: L10n.k("auto.privacy_filter.sample_meeting", fallback: "项目会议纪要"),
            icon: "bubble.left.and.bubble.right.fill",
            content: """
            关于新一代自主代理架构 Lobster-AI 的技术评审会。
            时间：2026年6月16日
            参会人：产品总监王明，首席技术架构师 Alex，安全总监周建国。

            会议决议：
            1. 考虑到代码和模型资产保密，内网代码托管地址应设为私有：https://github.com/internal-corp/lobster-ai.git。
            2. Alex 提到测试网关的 Bearer Token 为 8f3c7d6e5a4b3c2d1e0f9a8b7c6d5e4f，请运维组在明天前回收。
            3. 周建国强调，所有外部测试账号必须进行物理脱敏，避免使用真实员工手机号 13800138000。
            """
        )
    ]

    private var redactionMappings: [PrivacyRedactionMapping] {
        engine.redactionMapping(from: spans)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()
                .background(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))

            HStack(spacing: 0) {
                // 左侧栏：输入框及敏感实体控制面板
                leftPanel
                    .frame(minWidth: 320, maxWidth: 460)

                Divider()
                    .background(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))

                // 右侧栏：脱敏预览与审计报告
                rightPanel
                    .frame(maxWidth: .infinity)
            }
        }
        .background(colorScheme == .dark ? Color(nsColor: .underPageBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        .overlay(toastOverlay, alignment: .bottom)
        .onAppear {
            runUISmokeIfNeeded()
        }
        .onChange(of: inputText) { _, _ in
            hasAnalyzedCurrentInput = false
            spans = []
            redactedText = ""
            restoredLLMText = ""
        }
    }

    // MARK: - 头部区域
    private var headerView: some View {
        ZStack {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                        Text(L10n.k("auto.ailab_view.back", fallback: "返回实验室"))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.035))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: clearAll) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.035))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help(L10n.k("auto.privacy_filter.clear_all", fallback: "清空当前输入"))

                Spacer()
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(LinearGradient(colors: [Color.blue, Color.cyan], startPoint: .top, endPoint: .bottom))
                Text(L10n.k("auto.privacy_filter.title", fallback: "内容本地脱敏"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(colorScheme == .dark ? Color.black.opacity(0.12) : Color(nsColor: .windowBackgroundColor).opacity(0.9))
    }

    // MARK: - 左侧面板：输入与控制
    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.k("auto.privacy_filter.engine_select", fallback: "检测引擎"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .help(L10n.k("auto.privacy_filter.engine_help", fallback: """
                    【Apple】：使用 macOS NaturalLanguage 和本地规则检测常见 PII 与 Secret。
                    【OpenAI q4】：只调用本地 ONNX q4 模型，便于单独观察模型检测效果。
                    """))
            }

            Picker("", selection: $selectedEngine) {
                Text(FilterEngineType.native.label).tag(FilterEngineType.native)
                Text(FilterEngineType.semanticLocal.label).tag(FilterEngineType.semanticLocal)
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedEngine) { _, _ in
                if !inputText.isEmpty {
                    runAnalysis()
                }
            }

            if selectedEngine == .semanticLocal {
                semanticModelPanel
            }

            engineCapabilityBanner

            Divider()
                .padding(.vertical, 2)

            Text(L10n.k("auto.privacy_filter.input_section", fallback: "待脱敏原始文本"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            // 文本输入框
            ZStack(alignment: .topTrailing) {
                TextEditor(text: $inputText)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .background(colorScheme == .dark ? Color.black.opacity(0.2) : Color.white)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 1)
                    )

                if inputText.isEmpty {
                    VStack {
                        HStack {
                            Text(L10n.k("auto.privacy_filter.input_placeholder", fallback: "在此处粘贴需要脱敏的合同、日志、简历或会议纪要..."))
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 14)
                                .padding(.leading, 12)
                            Spacer()
                        }
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }

            // 样例快速填入 (仅在未输入时展示)
            if inputText.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.k("auto.privacy_filter.load_sample", fallback: "快速载入测试样本体验："))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)

                    ForEach(samples, id: \.name) { sample in
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                inputText = sample.content
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: sample.icon)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.blue)
                                Text(sample.name)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }

            // 一键脱敏分析按钮
            if !inputText.isEmpty {
                Button(action: runAnalysis) {
                    HStack {
                        if isAnalyzing {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                            Text(L10n.k("auto.privacy_filter.analyzing", fallback: "神经网络扫描分析中..."))
                        } else {
                            Image(systemName: "sparkles")
                            Text(L10n.k("auto.privacy_filter.run_redact", fallback: "本地一键隐私脱敏"))
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(colors: [Color.blue, Color(nsColor: .systemPurple)], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(8)
                    .shadow(color: Color.blue.opacity(colorScheme == .dark ? 0.3 : 0.15), radius: 6, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(isAnalyzing)
            }

            // 敏感实体控制面板 (已有分析结果时展示)
            if !spans.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.k("auto.privacy_filter.control_panel", fallback: "敏感项识别清单 (勾选以保留原文)"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach($spans) { $span in
                                HStack {
                                    // 实体分类徽章
                                    Text(span.type.label)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(span.type.color)
                                        .cornerRadius(4)

                                    Text(span.text)
                                        .font(.system(size: 12, design: .monospaced))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    Text(span.placeholder)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .padding(.trailing, 6)

                                    // 忽略切换开关
                                    Toggle("", isOn: $span.isIgnored)
                                        .toggleStyle(.checkbox)
                                        .onChange(of: span.isIgnored) { _, _ in
                                            updateRedactedText()
                                        }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.015))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
                .transition(.slide)
            }
        }
        .padding(18)
    }

    // MARK: - 右侧面板：结果与三种视图
    private var rightPanel: some View {
        VStack(spacing: 0) {
            if isAnalyzing {
                // 加载中神经扫描动效
                VStack(spacing: 20) {
                    Spacer()
                    ZStack {
                        Circle()
                            .stroke(Color.blue.opacity(0.1), lineWidth: 6)
                            .frame(width: 80, height: 80)

                        Circle()
                            .trim(from: 0, to: scanProgress)
                            .stroke(
                                LinearGradient(colors: [Color.blue, Color.purple], startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round)
                            )
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))

                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 32))
                            .foregroundStyle(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .top, endPoint: .bottom))
                    }

                    VStack(spacing: 6) {
                        Text(selectedEngine == .semanticLocal ? L10n.k("auto.privacy_filter.moe_loading", fallback: "OpenAI q4 本地模型分析中...") : L10n.k("auto.privacy_filter.scanning", fallback: "Apple 本地检测中..."))
                            .font(.system(size: 14, weight: .bold))
                        Text(selectedEngine == .semanticLocal ? L10n.k("auto.privacy_filter.moe_desc", fallback: "仅运行 OpenAI q4 本地 ONNX 模型，不混入 Apple 检测结果。") : L10n.k("auto.privacy_filter.local_safety", fallback: "使用 macOS NaturalLanguage 与本地规则，数据不离机。"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasAnalyzedCurrentInput {
                // 空状态引导与双引擎能力介绍
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer().frame(height: 10)

                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.05))
                                .frame(width: 80, height: 80)

                            Image(systemName: "lock.shield")
                                .font(.system(size: 38))
                                .foregroundStyle(LinearGradient(colors: [Color.blue, Color(nsColor: .systemPurple)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        }

                        VStack(spacing: 8) {
                            Text(L10n.k("auto.privacy_filter.empty_title", fallback: "本地零信任沙盒保护"))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.primary)

                            Text(L10n.k("auto.privacy_filter.empty_desc", fallback: "将文本发送到大模型前，一键抹除其中的个人隐私与敏感 API Key，支持本地离线智能审计"))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }

                        engineComparisonTable

                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 三视图展示与操作栏
                VStack(spacing: 0) {
                    // 顶部视图模式选择器
                    VStack(spacing: 10) {
                        analysisStatusBanner

                        Picker("", selection: $viewMode) {
                            Text(L10n.k("auto.privacy_filter.mode_diff", fallback: "左右对比")).tag(0)
                            Text(L10n.k("auto.privacy_filter.mode_highlight", fallback: "高亮标注")).tag(1)
                            Text(L10n.k("auto.privacy_filter.mode_list", fallback: "变更列表")).tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.01))

                    Divider()
                        .background(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))

                    // 视图内容区
                    ZStack {
                        if viewMode == 0 {
                            // 左右对比
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L10n.k("auto.privacy_filter.original_title", fallback: "原文记录"))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.secondary)

                                    ScrollView {
                                        Text(inputText)
                                            .font(.system(size: 12, design: .monospaced))
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.01))
                                    .cornerRadius(6)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L10n.k("auto.privacy_filter.redacted_title", fallback: "已脱敏"))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.blue)

                                    ScrollView {
                                        Text(redactedText)
                                            .font(.system(size: 12, design: .monospaced))
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.01))
                                    .cornerRadius(6)
                                }
                            }
                            .padding(20)
                        } else if viewMode == 1 {
                            // 高亮标注
                            ScrollView {
                                buildHighlightedText(text: inputText, spans: spans)
                                    .padding(20)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.01))
                            .cornerRadius(8)
                            .padding(20)
                        } else {
                            // 变更列表
                            List {
                                Section(header: Text(L10n.k("auto.privacy_filter.audit_log", fallback: "本地审计替换明细"))) {
                                    ForEach(spans) { span in
                                        HStack(spacing: 16) {
                                            HStack(spacing: 6) {
                                                Circle()
                                                    .fill(span.type.color)
                                                    .frame(width: 6, height: 6)
                                                Text(span.type.label)
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(.secondary)
                                            }
                                            .frame(width: 80, alignment: .leading)

                                            Text(span.text)
                                                .font(.system(size: 13, design: .monospaced))
                                                .foregroundStyle(.primary)

                                            Image(systemName: "arrow.right")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.tertiary)

                                            Text(span.placeholder)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(.blue)

                                            Spacer()

                                            Text(String(format: "%.0f%%", span.confidence * 100))
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(.tertiary)

                                            if span.isIgnored {
                                                Text(L10n.k("auto.privacy_filter.ignored_status", fallback: "已被忽略"))
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.orange)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.orange.opacity(0.1))
                                                    .cornerRadius(4)
                                            } else {
                                                Text(L10n.k("auto.privacy_filter.redacted_status", fallback: "待脱敏"))
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.green)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.green.opacity(0.1))
                                                    .cornerRadius(4)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                            .listStyle(.inset)
                            .padding(10)
                        }
                    }
                    .frame(maxHeight: .infinity)

                    Divider()
                        .background(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))

                    // 底部操作区 (复制、导出、LLM 结果还原)
                    VStack(spacing: 0) {
                        HStack(spacing: 16) {
                            Spacer()

                            Button(action: exportToMarkdown) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text(L10n.k("auto.privacy_filter.export_md", fallback: "导出 Markdown"))
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)

                            Button(action: copyToClipboard) {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc.fill")
                                    Text(spans.isEmpty ? L10n.k("auto.privacy_filter.copy_result", fallback: "复制结果") : L10n.k("auto.privacy_filter.copy_text", fallback: "复制脱敏文本"))
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(16)

                        if !redactionMappings.isEmpty {
                            Divider()
                                .background(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
                            restorePanel
                        }
                    }
                    .background(colorScheme == .dark ? Color.black.opacity(0.1) : Color.white.opacity(0.8))
                }
            }
        }
    }

    private var analysisStatusBanner: some View {
        let modelUnavailable = selectedEngine == .semanticLocal && !engine.isSemanticModelReady
        let hasHits = !spans.isEmpty
        let iconName = modelUnavailable ? "exclamationmark.triangle.fill" : (hasHits ? "checkmark.shield.fill" : "checkmark.circle.fill")
        let tint: Color = modelUnavailable ? .orange : (hasHits ? .blue : .green)
        let title = modelUnavailable
            ? L10n.k("auto.privacy_filter.analysis_model_unavailable_title", fallback: "OpenAI q4 尚未安装")
            : hasHits
                ? L10n.f("auto.privacy_filter.analysis_hit_title_fmt", fallback: "检测到 %d 个敏感项", spans.count)
                : L10n.k("auto.privacy_filter.analysis_no_hit_title", fallback: "无需脱敏")
        let desc = modelUnavailable
            ? L10n.k("auto.privacy_filter.analysis_model_unavailable_desc", fallback: "请先安装 OpenAI q4 模型；当前模式不会混入 Apple 检测结果。")
            : hasHits
                ? L10n.k("auto.privacy_filter.analysis_hit_desc", fallback: "下方结果已替换命中的敏感内容，映射仅保存在本机。")
                : L10n.k("auto.privacy_filter.analysis_no_hit_desc", fallback: "本次检测没有命中敏感项，结果与原文一致。")

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(colorScheme == .dark ? 0.12 : 0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(colorScheme == .dark ? 0.25 : 0.18), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    private var restorePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(L10n.k("auto.privacy_filter.restore_title", fallback: "LLM 返回还原"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(L10n.f("auto.privacy_filter.mapping_count", fallback: "%d 项映射仅保存在本地", redactionMappings.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: restoreLLMOutput) {
                    Label(L10n.k("auto.privacy_filter.restore_button", fallback: "还原"), systemImage: "arrow.uturn.backward.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(llmOutputText.isEmpty)
                Button(action: copyRestoredToClipboard) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(restoredLLMText.isEmpty)
                .help(L10n.k("auto.privacy_filter.copy_restored", fallback: "复制还原文本"))
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.k("auto.privacy_filter.llm_output_input", fallback: "LLM 返回"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    TextEditor(text: $llmOutputText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 82, maxHeight: 110)
                        .padding(6)
                        .background(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.k("auto.privacy_filter.restored_output", fallback: "还原结果"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    ScrollView {
                        Text(restoredLLMText.isEmpty ? L10n.k("auto.privacy_filter.restored_placeholder", fallback: "粘贴 LLM 返回文本后点击还原") : restoredLLMText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(restoredLLMText.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 82, maxHeight: 110)
                    .background(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var semanticModelPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: engine.isSemanticModelReady ? "checkmark.seal.fill" : "externaldrive.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(engine.isSemanticModelReady ? .green : .blue)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 5) {
                    Text(PrivacySemanticModel.openAIPrivacyFilterQ4.label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(PrivacySemanticModel.openAIPrivacyFilterQ4.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(engine.selectedSemanticModelDirectory.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button {
                    engine.openSemanticModelDirectory()
                } label: {
                    Label(L10n.k("auto.privacy_filter.open_model_dir", fallback: "打开目录"), systemImage: "folder")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(L10n.k("auto.privacy_filter.open_model_dir_help", fallback: "在 Finder 中打开 OpenAI q4 模型目录"))

                if engine.isPreparingSemanticModel {
                    if let progress = engine.semanticModelProgress {
                        Text(progressPercentText(progress))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else if engine.isSemanticModelReady {
                    HStack(spacing: 6) {
                        Label(L10n.k("auto.privacy_filter.model_ready", fallback: "已安装"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)

                        Button {
                            installSemanticModel(force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.k("auto.privacy_filter.reinstall_model_help", fallback: "重新下载并覆盖当前模型"))
                    }
                } else {
                    Button {
                        installSemanticModel()
                    } label: {
                        Label(L10n.k("auto.privacy_filter.install_model", fallback: "安装"), systemImage: "arrow.down.circle")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(L10n.k("auto.privacy_filter.install_model_help", fallback: "通过独立脱敏命令行安装或刷新本地模型包"))
                }
            }

            if engine.isPreparingSemanticModel {
                q4DownloadProgressView
            }
        }
        .padding(10)
        .background(colorScheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 0.8)
        )
        .cornerRadius(6)
    }

    private var q4DownloadProgressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = engine.semanticModelProgress {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)

                Text(L10n.f(
                    "auto.privacy_filter.download_progress_fmt",
                    fallback: "下载 %@ · %@/s · %@ / %@",
                    progressPercentText(progress),
                    byteText(progress.bytesPerSecond),
                    byteText(Double(progress.downloadedBytes)),
                    byteText(Double(progress.totalBytes))
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

                if let currentFile = progress.currentFile, !currentFile.isEmpty {
                    Text(L10n.f("auto.privacy_filter.download_file_fmt", fallback: "当前文件：%@", currentFile))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(L10n.k("auto.privacy_filter.download_preparing", fallback: "准备下载 q4 模型..."))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 特性辅助微卡片
    private func featureBullet(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.blue)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - 逻辑操作

    private func runAnalysis() {
        guard !inputText.isEmpty else { return }
        isAnalyzing = true
        hasAnalyzedCurrentInput = false
        scanProgress = 0.0

        // 模拟神经网络扫描动画以增强用户体验
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            withAnimation(.linear(duration: 0.05)) {
                // OpenAI q4 需要本地模型推理，扫描动画稍慢
                scanProgress += (selectedEngine == .semanticLocal ? 0.04 : 0.08)
            }
            if scanProgress >= 1.0 {
                timer.invalidate()
                let currentInput = inputText
                let currentEngine = selectedEngine

                // 执行真正的本地脱敏识别分析
                Task {
                    let result = await engine.analyze(text: currentInput, engineType: currentEngine)

                    await MainActor.run {
                        guard inputText == currentInput, selectedEngine == currentEngine else {
                            isAnalyzing = false
                            return
                        }

                        withAnimation(.easeInOut(duration: 0.2)) {
                            spans = result
                            isAnalyzing = false
                            hasAnalyzedCurrentInput = true
                            updateRedactedText()
                        }
                    }
                }
            }
        }
    }

    private func updateRedactedText() {
        redactedText = engine.redact(text: inputText, spans: spans)
        if !llmOutputText.isEmpty {
            restoreLLMOutput()
        }
    }

    private func clearAll() {
        withAnimation {
            inputText = ""
            spans = []
            redactedText = ""
            llmOutputText = ""
            restoredLLMText = ""
            hasAnalyzedCurrentInput = false
            scanProgress = 0.0
            isAnalyzing = false
        }
    }

    private func installSemanticModel(force: Bool = false) {
        engine.selectedSemanticModel = selectedSemanticModel
        Task {
            await engine.prepareSemanticModel(force: force)
            if engine.isSemanticModelReady, !inputText.isEmpty {
                runAnalysis()
            }
        }
    }

    private func progressPercentText(_ progress: PrivacyModelDownloadProgress) -> String {
        "\(Int(progress.fractionCompleted * 100))%"
    }

    private func byteText(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: max(0, Int64(value)))
    }

    private func runUISmokeIfNeeded() {
        guard !hasRunUISmoke,
              ProcessInfo.processInfo.environment["CLAWDHOME_PRIVACY_FILTER_UI_SMOKE"] == "1"
        else { return }
        hasRunUISmoke = true

        let environment = ProcessInfo.processInfo.environment
        let smokeEngine: FilterEngineType = environment["CLAWDHOME_PRIVACY_FILTER_UI_SMOKE_ENGINE"] == "apple" ? .native : .semanticLocal
        selectedEngine = smokeEngine
        selectedSemanticModel = .openAIPrivacyFilterQ4
        engine.selectedSemanticModel = .openAIPrivacyFilterQ4

        let smokeInput = environment["CLAWDHOME_PRIVACY_FILTER_UI_SMOKE_INPUT"] ?? "My email is harry.potter@hogwarts.edu and my phone is 415-555-0101."
        inputText = smokeInput

        Task {
            let result = await engine.analyze(text: smokeInput, engineType: smokeEngine)
            await MainActor.run {
                spans = result
                hasAnalyzedCurrentInput = true
                redactedText = engine.redact(text: smokeInput, spans: result)
                writeUISmokeResult(spans: result, redactedText: redactedText)
                NSApp.terminate(nil)
            }
        }
    }

    private func writeUISmokeResult(spans: [PrivacySpan], redactedText: String) {
        guard let outputPath = ProcessInfo.processInfo.environment["CLAWDHOME_PRIVACY_FILTER_UI_SMOKE_RESULT"] else {
            return
        }

        let payload: [String: Any] = [
            "ok": hasAnalyzedCurrentInput,
            "engine": String(describing: selectedEngine),
            "model": selectedSemanticModel.rawValue,
            "modelReady": engine.isSemanticModelReady,
            "redactedText": redactedText,
            "spans": spans.map { span in
                [
                    "text": span.text,
                    "type": span.type.rawValue,
                    "placeholder": span.placeholder,
                    "start": span.startOffset,
                    "end": span.endOffset,
                ] as [String: Any]
            },
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }

        try? data.write(to: URL(fileURLWithPath: outputPath), options: [.atomic])
    }

    private func restoreLLMOutput() {
        restoredLLMText = engine.restore(text: llmOutputText, mappings: redactionMappings)
    }

    private func copyRestoredToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(restoredLLMText, forType: .string)
        showToast(message: L10n.k("auto.privacy_filter.copy_restored_success", fallback: "已复制还原文本"))
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(redactedText, forType: .string)
        showToast(message: L10n.k("auto.privacy_filter.copy_success", fallback: "已复制到剪贴板"))
    }

    private func exportToMarkdown() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.plainText, UTType(filenameExtension: "md")].compactMap { $0 }
        savePanel.nameFieldStringValue = "redacted_document.md"
        savePanel.title = L10n.k("auto.privacy_filter.export_title", fallback: "导出脱敏 Markdown 文件")

        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                var report = "# " + L10n.k("auto.privacy_filter.report_title", fallback: "本地脱敏文档") + "\n\n"
                report += redactedText
                report += "\n\n---\n"
                report += "## " + L10n.k("auto.privacy_filter.report_subtitle", fallback: "本地审计脱敏报告") + "\n"
                report += "- **" + L10n.k("auto.privacy_filter.report_time", fallback: "处理时间") + "**: \(Date().description)\n"
                report += "- **" + L10n.k("auto.privacy_filter.report_summary", fallback: "过滤实体明细") + "**:\n"

                let activeSpans = spans.filter { !$0.isIgnored }
                let grouped = Dictionary(grouping: activeSpans, by: { $0.type })

                for (type, items) in grouped {
                    let examples = Array(Set(items.map { $0.placeholder })).prefix(3).joined(separator: ", ")
                    report += "  - **\(type.label)**: " + String(format: L10n.k("auto.privacy_filter.report_group_count", fallback: "发现 %d 处"), items.count) + " (\(examples))\n"
                }

                do {
                    try report.write(to: url, atomically: true, encoding: .utf8)
                    showToast(message: L10n.k("auto.privacy_filter.export_success", fallback: "文件导出成功"))
                } catch {
                    showToast(message: L10n.k("auto.privacy_filter.export_failed", fallback: "导出失败，请重试"))
                }
            }
        }
    }

    private func showToast(message: String) {
        toastMessage = message
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            showToast = true
        }

        // 2秒后自动消失
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeIn(duration: 0.25)) {
                showToast = false
            }
        }
    }

    // MARK: - Toast 浮层
    private var toastOverlay: some View {
        Group {
            if showToast {
                Text(toastMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(20)
                    .shadow(color: Color.black.opacity(0.2), radius: 10, y: 5)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 能力边界 Banner 视图
    private var engineCapabilityBanner: some View {
        // 1. 提取图标名称
        let iconName: String
        if selectedEngine == .semanticLocal {
            iconName = engine.isSemanticModelReady ? "sparkles" : "exclamationmark.triangle.fill"
        } else {
            iconName = "info.circle.fill"
        }

        // 2. 提取渐变色
        let iconGradient: LinearGradient
        if selectedEngine == .semanticLocal {
            if engine.isSemanticModelReady {
                iconGradient = LinearGradient(colors: [.purple, .pink], startPoint: .top, endPoint: .bottom)
            } else {
                iconGradient = LinearGradient(colors: [.orange, .yellow], startPoint: .top, endPoint: .bottom)
            }
        } else {
            iconGradient = LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom)
        }

        // 3. 提取说明文本
        let descText: String
        if selectedEngine == .semanticLocal {
            if engine.isSemanticModelReady {
                descText = L10n.k("auto.privacy_filter.openai_banner_desc", fallback: "OpenAI q4 模型已就绪：当前只运行本地 ONNX 推理，不混入 Apple 检测结果。")
            } else if let errorMessage = engine.semanticModelErrorMessage, !errorMessage.isEmpty {
                descText = L10n.f("auto.privacy_filter.model_error_fmt", fallback: "OpenAI q4 模型安装失败：%@", errorMessage)
            } else {
                descText = L10n.k("auto.privacy_filter.moe_loading_desc", fallback: "OpenAI q4 模型尚未安装。点击安装会调用独立命令行下载模型包；也可打开目录检查模型资产。")
            }
        } else {
            descText = L10n.k("auto.privacy_filter.native_banner_desc", fallback: "Apple 检测已启用：使用 macOS NaturalLanguage、正则和 Secret 规则在本机完成脱敏。")
        }

        // 4. 提取背景及边框颜色
        let bgColor: Color
        let strokeColor: Color
        if selectedEngine == .semanticLocal {
            if engine.isSemanticModelReady {
                bgColor = Color.purple.opacity(0.06)
                strokeColor = Color.purple.opacity(0.15)
            } else {
                bgColor = Color.orange.opacity(0.06)
                strokeColor = Color.orange.opacity(0.15)
            }
        } else {
            bgColor = Color.blue.opacity(0.06)
            strokeColor = Color.blue.opacity(0.15)
        }

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(iconGradient)
                .padding(.top, 1)

            Text(descText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(bgColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(strokeColor, lineWidth: 0.8)
        )
        .transition(.asymmetric(insertion: .push(from: .top).combined(with: .opacity), removal: .opacity))
    }

    // MARK: - 端侧脱敏引擎对比卡片
    private var engineComparisonTable: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.k("auto.privacy_filter.comp_table_title", fallback: "端侧脱敏引擎能力对照"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                // 表头
                HStack(spacing: 0) {
                    Text(L10n.k("auto.privacy_filter.comp_col_feature", fallback: "对比维度"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)

                    Text(FilterEngineType.native.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(FilterEngineType.semanticLocal.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.purple)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))

                Divider()

                // 表身行
                comparisonRow(
                    dimension: L10n.k("auto.privacy_filter.comp_row_tech", fallback: "技术原理"),
                    native: L10n.k("auto.privacy_filter.comp_row_tech_nat", fallback: "macOS NaturalLanguage + 本地规则"),
                    openai: L10n.k("auto.privacy_filter.comp_row_tech_ope", fallback: "OpenAI q4 本地 ONNX")
                )

                comparisonRow(
                    dimension: L10n.k("auto.privacy_filter.comp_row_speed", fallback: "运行速度"),
                    native: L10n.k("auto.privacy_filter.comp_row_speed_nat", fallback: "极速 (< 1ms)，零装载开销"),
                    openai: L10n.k("auto.privacy_filter.comp_row_speed_ope", fallback: "需装载本地 ONNX 模型")
                )

                comparisonRow(
                    dimension: L10n.k("auto.privacy_filter.comp_row_footprint", fallback: "系统占用"),
                    native: L10n.k("auto.privacy_filter.comp_row_footprint_nat", fallback: "近乎 0MB，极低开销"),
                    openai: L10n.k("auto.privacy_filter.comp_row_footprint_ope", fallback: "约 945 MB 模型资产")
                )

                comparisonRow(
                    dimension: L10n.k("auto.privacy_filter.comp_row_range", fallback: "核心识别范围"),
                    native: L10n.k("auto.privacy_filter.comp_row_range_nat", fallback: "基础个人 PII（姓名/地名/手机/邮箱/身份证/银行卡）及常见 Secret"),
                    openai: L10n.k("auto.privacy_filter.comp_row_range_ope", fallback: "模型独立识别的上下文 PII")
                )
            }
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
            )
        }
        .padding(16)
        .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.015))
        .cornerRadius(12)
        .padding(.horizontal, 24)
        .frame(maxWidth: 500)
    }

    private func comparisonRow(dimension: String, native: String, openai: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Text(dimension)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)

                Text(native)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)

                Text(openai)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)

            Divider()
        }
    }

    // MARK: - 原生富文本构建方法
    private func buildHighlightedText(text: String, spans: [PrivacySpan]) -> Text {
        guard !text.isEmpty else { return Text("") }

        var attrString = AttributedString(text)

        for span in spans {
            guard span.startOffset < text.count && span.endOffset <= text.count else { continue }

            let startIdx = text.index(text.startIndex, offsetBy: span.startOffset)
            let endIdx = text.index(text.startIndex, offsetBy: span.endOffset)

            if let attrStart = AttributedString.Index(startIdx, within: attrString),
               let attrEnd = AttributedString.Index(endIdx, within: attrString) {
                let range = attrStart..<attrEnd

                if span.isIgnored {
                    attrString[range].underlineStyle = .single
                    attrString[range].foregroundColor = .orange
                } else {
                    attrString[range].backgroundColor = span.type.color.opacity(0.18)
                    attrString[range].foregroundColor = span.type.color
                    attrString[range].font = .system(size: 13, weight: .bold, design: .monospaced)
                }
            }
        }

        return Text(attrString)
    }
}
