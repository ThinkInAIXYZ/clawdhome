// ClawdHome/Views/DashboardView.swift

import Charts
import SwiftUI

private let kHistoryMax = 300   // 与 ShrimpPool.kHistoryMax 对齐
private let kSmallCardPoints = 60  // 小卡片显示最近 60 秒

struct DashboardView: View {
    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self)   private var pool
    @Environment(GatewayHub.self) private var gatewayHub
    @State private var userRecords: [UserRecord] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !helperClient.isConnected {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(L10n.k("dashboard.helper_disconnected_hint", fallback: "Helper 未连接，数据无法获取。请前往「设置 → 诊断」查看详情。"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                // 2. ClawdHome 概览 (极致打磨的 3x2 对称科技卡片网格)
                DashboardSection(title: L10n.k("dashboard.section.clawdhome_overview", fallback: "💻 ClawdHome 概览"), icon: "desktopcomputer") {
                    MachineStatsGrid(
                        stats: pool.snapshot?.machine,
                        history: pool.machineHistory,
                        netRateHistory: pool.netRateHistory,
                        shrimps: pool.snapshot?.shrimps ?? []
                    )
                }

                Divider()

                // 3. 虾塘概览 (极致磨砂发光药丸 + 水印聚合卡片)
                DashboardSection(title: L10n.k("dashboard.section.shrimp_pool_overview", fallback: "🦞 虾塘概览"), icon: "network") {
                    ShrimpNetworkSection(
                        shrimps: pool.snapshot?.shrimps ?? [],
                        total: pool.snapshot?.totalShrimpCount ?? 0,
                        running: pool.snapshot?.runningShrimpCount ?? 0
                    )
                }

                Divider()

                // 4. 流量、存储与资产 (高度还原双列分栏 + 积木式卡片行与彩绘图标)
                DashboardSection(title: L10n.k("dashboard.section.asset_overview", fallback: "📊 资产与存储明细"), icon: "shippingbox.fill") {
                    DashboardSplitRow(shrimps: pool.snapshot?.shrimps ?? [])
                }
            }
            .padding(20)
        }
        .navigationTitle(L10n.k("dashboard.title", fallback: "仪表盘"))
        // 触发 HTTP 探活（视图本地逻辑）
        .onChange(of: pool.snapshotVersion) { _, _ in
            guard let s = pool.snapshot else { return }
            updateProbes(s)
        }
    }

    private func updateProbes(_ s: DashboardSnapshot) {
        // 优先用快照中的实际端口（可能因冲突偏移），回退到 18000+uid 公式
        let allProbes: [(username: String, port: Int)] = s.shrimps.compactMap { shrimp in
            if shrimp.gatewayPort > 0 {
                return (shrimp.username, shrimp.gatewayPort)
            }
            // 旧 Helper 快照无 gatewayPort 字段，从本地用户记录计算
            guard let rec = userRecords.first(where: { $0.username == shrimp.username }),
                  let port = GatewayHub.gatewayPort(for: rec.uid) else { return nil }
            return (shrimp.username, port)
        }
        let isRunningMap = Dictionary(
            uniqueKeysWithValues: s.shrimps.map { ($0.username, $0.isRunning ?? false) }
        )
        gatewayHub.updateProbes(all: allProbes, isRunning: isRunningMap)

        // 若 userRecords 为空则异步加载（userInitiated QoS，不阻塞 UI 线程）
        if userRecords.isEmpty {
            Task {
                if let records = try? await UserDirectoryService.listStandardUsersAsync() {
                    userRecords = records
                }
            }
        }
    }
}

// MARK: - 通用区块容器

struct DashboardSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
            content()
        }
    }
}

// MARK: - 本机概览网格 (极致美学打磨：3x2 完美对称科技卡片网格)

struct MachineStatsGrid: View {
    let stats: MachineStats?
    var history: [MachineStats] = []
    var netRateHistory: [(inBps: Double, outBps: Double)] = []
    var shrimps: [ShrimpNetStats] = []

    private var currentNetIn:  Double { shrimps.reduce(0.0) { $0 + $1.netRateInBps } }
    private var currentNetOut: Double { shrimps.reduce(0.0) { $0 + $1.netRateOutBps } }

    private var netTotalSamples: [Double] {
        netRateHistory.map { $0.inBps + $0.outBps }
    }
    private var netRange: ClosedRange<Double> {
        let peak = netTotalSamples.max() ?? 0
        return 0...(max(peak, 1024))
    }

    @State private var expanded: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            // 展开的大图
            if let exp = expanded, let card = cards.first(where: { $0.title == exp }),
               !card.samples.isEmpty {
                ExpandedChartCard(card: card) {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded = nil }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // 对称流式网格，对应 HTML 的 overview-row (在宽屏下固定为3列对称)
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14)
            ], spacing: 14) {
                // 1. CPU 卡片 (折线)
                let cpuSamples = history.map { $0.cpuPercent }
                let cpuValue = stats.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "—"
                MiniChartCard(
                    title: dynamicText(zh: "CPU 占用", en: "CPU Usage"),
                    value: cpuValue,
                    icon: "cpu",
                    theme: .blue,
                    samples: Array(cpuSamples.suffix(kSmallCardPoints)),
                    range: 0...100
                )
                .opacity(expanded == "CPU" ? 0.5 : 1)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded = expanded == "CPU" ? nil : "CPU"
                    }
                }

                // 2. GPU 卡片 (折线)
                let gpuSamples = history.compactMap { $0.gpuPercent }
                let gpuValue = stats?.gpuPercent.map { String(format: "%.0f%%", $0) } ?? "0%"
                MiniChartCard(
                    title: dynamicText(zh: "GPU 占用", en: "GPU Usage"),
                    value: gpuValue,
                    icon: "square.stack.3d.up.fill",
                    theme: .purple,
                    samples: Array(gpuSamples.suffix(kSmallCardPoints)),
                    range: 0...100
                )
                .opacity(expanded == "GPU" ? 0.5 : 1)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded = expanded == "GPU" ? nil : "GPU"
                    }
                }

                // 3. 网络带宽卡片 (折线)
                let totalNetIn = stats?.netRateInBps ?? currentNetIn
                let totalNetOut = stats?.netRateOutBps ?? currentNetOut
                let netValue = "↓ \(FormatUtils.formatBps(totalNetIn))"
                let netValue2 = "↑ \(FormatUtils.formatBps(totalNetOut))"
                MiniChartCard(
                    title: L10n.k("common.resource.network", fallback: "网络带宽"),
                    value: netValue,
                    value2: netValue2,
                    icon: "arrow.up.arrow.down",
                    theme: .blue,
                    samples: Array(netTotalSamples.suffix(kSmallCardPoints)),
                    range: netRange
                )
                .opacity(expanded == L10n.k("common.resource.network", fallback: "网络带宽") ? 0.5 : 1)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        let term = L10n.k("common.resource.network", fallback: "网络带宽")
                        expanded = expanded == term ? nil : term
                    }
                }

                // 4. 内存 RAM 卡片 (折线)
                let memSamples = history.map { Double($0.memUsedMB) / max(Double($0.memTotalMB), 1.0) * 100.0 }
                let memValue = stats.map { String(format: "%.0f/%.0f GB", $0.memUsedMB / 1024, $0.memTotalMB / 1024) } ?? "—"
                MiniChartCard(
                    title: L10n.k("common.resource.memory", fallback: "内存 (RAM)"),
                    value: memValue,
                    icon: "memorychip",
                    theme: .purple,
                    samples: Array(memSamples.suffix(kSmallCardPoints)),
                    range: 0...100
                )
                .opacity(expanded == "RAM" ? 0.5 : 1)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded = expanded == "RAM" ? nil : "RAM"
                    }
                }

                // 5. 磁盘容量卡片 (进度条)
                let diskUsed = stats?.diskUsedGB ?? 0
                let diskTotal = max(stats?.diskTotalGB ?? 1, 1)
                let diskPercent = diskUsed / diskTotal
                let diskValue = stats.map { String(format: "%.0f/%.0f GB", $0.diskUsedGB, $0.diskTotalGB) } ?? "—"
                MiniProgressCard(
                    title: L10n.k("common.resource.disk", fallback: "磁盘容量"),
                    value: diskValue,
                    percent: diskPercent,
                    icon: "internaldrive",
                    theme: .emerald
                )

                // 6. 环境状态 / 温度卡片 (二选一平铺，保证对称)
                if let temp = stats?.cpuTempCelsius {
                    let tempPercent = min(max(temp, 0) / 100.0, 1.0)
                    MiniProgressCard(
                        title: L10n.k("common.resource.temperature", fallback: "温度"),
                        value: String(format: "%.0f°C", temp),
                        percent: tempPercent,
                        icon: "thermometer.medium",
                        theme: .orange
                    )
                } else {
                    // 温度不可用时，填充炫酷的系统隔离状态卡片，动态显示芯片与沙箱，保证 3x2 网格恒定对称
                    SystemStatusCard()
                }
            }
        }
    }

    private var cards: [CardData] {
        var result: [CardData] = []
        result.append(CardData(
            title: "CPU",
            value: stats.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "—",
            icon: "cpu", theme: .blue,
            samples: history.map { $0.cpuPercent },
            range: 0...100
        ))
        if stats?.gpuPercent != nil || history.contains(where: { $0.gpuPercent != nil }) {
            result.append(CardData(
                title: "GPU",
                value: stats?.gpuPercent.map { String(format: "%.0f%%", $0) } ?? "—",
                icon: "square.stack.3d.up.fill", theme: .purple,
                samples: history.compactMap { $0.gpuPercent },
                range: 0...100
            ))
        }
        result.append(CardData(
            title: "RAM",
            value: stats.map { String(format: "%.0f/%.0f GB", $0.memUsedMB / 1024, $0.memTotalMB / 1024) } ?? "—",
            icon: "memorychip", theme: .purple,
            samples: history.map { Double($0.memUsedMB) / max(Double($0.memTotalMB), 1.0) * 100.0 },
            range: 0...100
        ))

        let totalNetIn = stats?.netRateInBps ?? currentNetIn
        let totalNetOut = stats?.netRateOutBps ?? currentNetOut
        let netValue = "↓ \(FormatUtils.formatBps(totalNetIn))"
        let netValue2 = "↑ \(FormatUtils.formatBps(totalNetOut))"
        result.append(CardData(
            title: L10n.k("common.resource.network", fallback: "网络带宽"),
            value: netValue,
            value2: netValue2,
            icon: "arrow.up.arrow.down", theme: .blue,
            samples: netTotalSamples,
            range: netRange
        ))
        return result
    }
}

// MARK: - MiniChartCard (用于 CPU / GPU，Widget 风格小插件)

struct MiniChartCard: View {
    let title: String
    let value: String
    var value2: String? = nil
    let icon: String
    let theme: DesignSystem.GradientTheme
    let samples: [Double]
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                // 发光图标底板
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.gradient.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.gradient)
                }

                Spacer()

                // 大字数值
                VStack(alignment: .trailing, spacing: 1) {
                    Text(value)
                        .font(.system(size: value2 != nil ? 13 : 18, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.gradient)
                    if let value2 {
                        Text(value2)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            // 饱满折线图
            if !samples.isEmpty {
                MiniSparkline(samples: samples, range: range, color: theme.mainColor, maxPoints: kSmallCardPoints)
                    .frame(height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Spacer().frame(height: 32)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(height: 104)
        .premiumCard(theme: theme)
    }
}

// MARK: - MiniProgressCard (用于 RAM、网络、磁盘、环境等，Widget 风格小插件)

struct MiniProgressCard: View {
    let title: String
    let value: String
    var value2: String? = nil
    let percent: Double
    let icon: String
    let theme: DesignSystem.GradientTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                // 发光图标底板
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.gradient.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.gradient)
                }

                Spacer()

                // 大字数值
                VStack(alignment: .trailing, spacing: 1) {
                    Text(value)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                    if let value2 {
                        Text(value2)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            // 发光进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.gradient)
                        .frame(width: max(0, min(geo.size.width * CGFloat(percent), geo.size.width)), height: 6)
                        .shadow(color: theme.mainColor.opacity(0.4), radius: 3, x: 0, y: 0)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(height: 104)
        .premiumCard(theme: theme)
    }
}

// MARK: - 卡片数据模型

private struct CardData {
    let title: String
    let value: String
    var value2: String? = nil
    var cumulativeIn: String? = nil
    var cumulativeOut: String? = nil
    let icon: String
    let theme: DesignSystem.GradientTheme
    let samples: [Double]
    let range: ClosedRange<Double>
}

// MARK: - 展开的大图卡片

private struct ExpandedChartCard: View {
    let card: CardData
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: card.icon)
                    .foregroundStyle(card.theme.mainColor)
                Text(card.title).font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(card.value)
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.semibold)
                    if let v2 = card.value2 {
                        Text(v2)
                            .font(.system(.title3, design: .monospaced))
                            .fontWeight(.semibold)
                    }
                }
                if let ci = card.cumulativeIn, let co = card.cumulativeOut {
                    Divider().frame(height: 36).padding(.horizontal, 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 3) {
                            Text(L10n.k("dashboard.cumulative", fallback: "累计")).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text("↓ \(ci)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text("↑ \(co)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            MiniSparkline(samples: card.samples, range: card.range, color: card.theme.mainColor)
                .frame(height: 120)
        }
        .premiumCard(theme: card.theme)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
    }
}

// 折线波形图

struct MiniSparkline: View {
    let samples: [Double]
    let range: ClosedRange<Double>
    let color: Color
    var maxPoints: Int = kHistoryMax

    private struct Sample: Identifiable {
        let id: Int
        let value: Double
    }

    private var data: [Sample] {
        samples.enumerated().map { Sample(id: $0.offset, value: $0.element) }
    }

    var body: some View {
        if samples.isEmpty {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(p, with: .color(color.opacity(0.2)), lineWidth: 1)
            }
        } else {
            Chart(data) { s in
                LineMark(
                    x: .value("t", s.id),
                    y: .value("v", s.value)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2.0)) // 稍微加粗，显示效果更佳
                .interpolationMethod(.linear)

                AreaMark(
                    x: .value("t", s.id),
                    y: .value("v", s.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.24), color.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.linear)
            }
            .chartXAxis(.hidden)
            .chartXScale(domain: 0...(maxPoints - 1))
            .chartYAxis(.hidden)
            .chartYScale(domain: range)
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                plot.background(color.opacity(0.04))
            }
        }
    }
}

// MARK: - 四态状态指示点

struct GatewayStatusDot: View {
    let readiness: GatewayReadiness
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
            .scaleEffect(readiness == .starting ? (pulse ? 1.3 : 1.0) : 1.0)
            .animation(
                readiness == .starting
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { if readiness == .starting { pulse = true } }
            .onChange(of: readiness) { _, new in pulse = (new == .starting) }
            .help(dotLabel)
    }

    private var dotColor: Color {
        switch readiness {
        case .stopped:  .secondary.opacity(0.35)
        case .starting: .yellow
        case .ready:    .green
        case .zombie:   .red
        }
    }

    private var dotLabel: String {
        switch readiness {
        case .stopped:  L10n.k("dashboard.gateway_status.stopped", fallback: "已停止")
        case .starting: L10n.k("dashboard.gateway_status.starting", fallback: "启动中…")
        case .ready:    L10n.k("dashboard.gateway_status.ready", fallback: "就绪")
        case .zombie:   L10n.k("dashboard.gateway_status.zombie", fallback: "异常：进程存活但 HTTP 服务无响应，建议重启")
        }
    }
}

// MARK: - 虾塘概览板块 (极致磨砂呼吸状态药丸和暗影水印聚合卡片)

struct ShrimpNetworkSection: View {
    let shrimps: [ShrimpNetStats]
    let total: Int
    let running: Int

    @Environment(GatewayHub.self) private var gatewayHub
    private var activeShrimps: [ShrimpNetStats] { shrimps.filter { $0.isRunning ?? false } }
    private var totalCPU: Double { activeShrimps.compactMap(\.cpuPercent).reduce(0, +) }
    private var totalMemMB: Double { activeShrimps.compactMap(\.memRssMB).reduce(0, +) }
    private var totalStorage: Int64 { shrimps.reduce(0) { $0 + max(0, $1.openclawDirBytes) } }

    private var avgStorageLabel: String {
        guard total > 0 else { return "—" }
        return FormatUtils.formatBytes(totalStorage / Int64(total))
    }

    private var memLabel: String {
        totalMemMB >= 1024 ? String(format: "%.1f GB", totalMemMB / 1024) : String(format: "%.0f MB", totalMemMB)
    }

    private var cpuLabel: String { String(format: "%.0f%%", totalCPU) }

    private var readyCount: Int { shrimps.filter { readiness(for: $0) == .ready }.count }
    private var startingCount: Int { shrimps.filter { readiness(for: $0) == .starting }.count }
    private var zombieCount: Int { shrimps.filter { readiness(for: $0) == .zombie }.count }

    private func readiness(for shrimp: ShrimpNetStats) -> GatewayReadiness {
        if let state = gatewayHub.readinessMap[shrimp.username] { return state }
        return (shrimp.isRunning ?? false) ? .ready : .stopped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if shrimps.isEmpty {
                VStack(spacing: 8) {
                    Text("🦞")
                        .font(.largeTitle)
                        .opacity(0.3)
                    Text(L10n.k("dashboard.no_shrimps", fallback: "暂无虾"))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
                .premiumCard(theme: .slate)
            } else {
                // 1. 磨砂发光状态药丸行 (shrimp-status-row)
                HStack(spacing: 10) {
                    ShrimpStatusPill(title: L10n.k("dashboard.shrimp_status.running", fallback: "运行"), value: "\(running)/\(total)", tint: .secondary)
                    ShrimpStatusPill(title: L10n.k("dashboard.shrimp_status.ready", fallback: "就绪"), value: "\(readyCount)", tint: .green)
                    ShrimpStatusPill(title: L10n.k("dashboard.shrimp_status.starting", fallback: "启动中"), value: "\(startingCount)", tint: .yellow)
                    ShrimpStatusPill(title: L10n.k("dashboard.shrimp_status.anomaly", fallback: "异常"), value: "\(zombieCount)", tint: zombieCount > 0 ? .red : .secondary)
                }

                // 2. 极致打磨的聚合大卡片 (3列网格，高度与硬件概览卡片104一致，极其对称)
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ], spacing: 14) {
                    // CPU 汇总
                    DashboardAggregateCard(
                        title: L10n.k("dashboard.card.cpu_summary", fallback: "💻 CPU 汇总"),
                        value: cpuLabel,
                        desc: L10n.f("dashboard.card.active_shrimps", fallback: "活跃 %d 只虾", activeShrimps.count),
                        icon: "cpu",
                        theme: .blue
                    )

                    // 内存汇总
                    DashboardAggregateCard(
                        title: L10n.k("dashboard.card.memory_summary", fallback: "🧠 内存汇总"),
                        value: memLabel,
                        desc: L10n.k("dashboard.card.process_memory", fallback: "进程物理内存"),
                        icon: "brain.head.profile",
                        theme: .purple
                    )

                    // 存储占用
                    DashboardAggregateCard(
                        title: L10n.k("dashboard.card.storage_usage", fallback: "💾 存储占用"),
                        value: FormatUtils.formatBytes(totalStorage),
                        desc: L10n.f("dashboard.card.avg_storage", fallback: "平均每只虾 %@", avgStorageLabel),
                        icon: "internaldrive",
                        theme: .emerald
                    )
                }
            }
        }
    }
}

// MARK: - 状态磨砂发光药丸组件

private struct ShrimpStatusPill: View {
    let title: String
    let value: String
    let tint: Color

    @State private var isBreathing = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)

                if tint != .secondary {
                    Circle()
                        .stroke(tint, lineWidth: 2)
                        .scaleEffect(isBreathing ? 2.2 : 1.0)
                        .opacity(isBreathing ? 0.0 : 0.6)
                        .frame(width: 6, height: 6)
                }
            }
            .onAppear {
                if tint != .secondary {
                    withAnimation(
                        .easeInOut(duration: 1.8)
                        .repeatForever(autoreverses: false)
                    ) {
                        isBreathing = true
                    }
                }
            }

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint == .secondary ? .secondary : tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial) // 磨砂玻璃拟态
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.15), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
        )
        .shadow(color: tint.opacity(0.12), radius: 4, x: 0, y: 2)
    }
}

// MARK: - 汇总大卡片组件 (dashboard-aggregates，含倾斜水印背景)

struct DashboardAggregateCard: View {
    let title: String
    let value: String
    let desc: String
    let icon: String
    let theme: DesignSystem.GradientTheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // 右下角 88pt 倾斜的水印大图标，极具设计品位
            Image(systemName: icon)
                .font(.system(size: 88, weight: .bold))
                .foregroundStyle(theme.gradient.opacity(0.04))
                .rotationEffect(.degrees(-12))
                .offset(x: 18, y: 18)
                .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(theme.gradient)
                    .padding(.vertical, 2)
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 104) // 与硬件概览高度完全对齐，极致工整
        .premiumCard(theme: theme)
    }
}

// MARK: - 流量与存储 Top 3 与资产明细分栏 (高度还原 HTML 版 dashboard-split-row + 积木圆角卡片行)

struct DashboardSplitRow: View {
    let shrimps: [ShrimpNetStats]

    private var totalStorage: Int64 { shrimps.reduce(0) { $0 + max(0, $1.openclawDirBytes) } }
    private var totalHomeBytes: Int64 { shrimps.reduce(0) { $0 + max(0, $1.homeDirBytes) } }
    private var totalMemBytes: Int64 { shrimps.reduce(0) { $0 + max(0, $1.memoryDirBytes) } }
    private var totalSkills: Int { shrimps.reduce(0) { $0 + $1.skillCount } }

    private var topStorageShrimps: [ShrimpNetStats] {
        shrimps
            .filter { $0.openclawDirBytes > 0 }
            .sorted { $0.openclawDirBytes > $1.openclawDirBytes }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // 左列：存储占用 Top 3
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.k("dashboard.storage_top3", fallback: "📊 存储占用 Top 3"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 4)

                if topStorageShrimps.isEmpty {
                    VStack(spacing: 6) {
                        Text("📁")
                            .font(.system(size: 24))
                            .opacity(0.3)
                        Text(dynamicText(zh: "暂无存储数据", en: "No storage data available"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
                } else {
                    VStack(spacing: 0) {
                        ForEach(topStorageShrimps, id: \.username) { shrimp in
                            HStack(spacing: 12) {
                                // 渐变人物图标
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(DesignSystem.GradientTheme.blue.gradient.opacity(0.12))
                                        .frame(width: 24, height: 24)
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(DesignSystem.GradientTheme.blue.gradient)
                                }

                                Text("@\(shrimp.username)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.primary)

                                Spacer()

                                Text(FormatUtils.formatBytes(shrimp.openclawDirBytes))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(Color.secondary.opacity(0.04)) // 积木卡片式微背景
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.bottom, 6)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .premiumCard(theme: .slate)

            // 右列：资产概览
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.k("dashboard.section.asset_overview", fallback: "📈 资产概览"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 4)

                VStack(spacing: 0) {
                    // 数据总量
                    AssetRow(
                        icon: "folder.fill",
                        label: dynamicText(zh: "🗄️ 数据总量", en: "Data Volume"),
                        value: "\(FormatUtils.formatBytes(totalStorage)) (\(shrimps.count) \(dynamicText(zh: "只虾", en: "shrimps")))",
                        theme: .blue
                    )

                    // 家目录总量
                    if totalHomeBytes > 0 {
                        AssetRow(
                            icon: "house.fill",
                            label: dynamicText(zh: "🏠 家目录总量", en: "Home Directory"),
                            value: "\(FormatUtils.formatBytes(totalHomeBytes)) (\(dynamicText(zh: "含所有文件", en: "incl. all files")))",
                            theme: .teal
                        )
                    }

                    // 记忆总量
                    AssetRow(
                        icon: "brain.head.profile",
                        label: dynamicText(zh: "🧠 记忆总量", en: "Total Memory"),
                        value: "\(FormatUtils.formatBytes(totalMemBytes)) (\(dynamicText(zh: "所有虾合计", en: "total for all")))",
                        theme: .purple
                    )

                    // 技能总数
                    AssetRow(
                        icon: "sparkles",
                        label: dynamicText(zh: "⚡ 技能总数", en: "Total Skills"),
                        value: L10n.f("dashboard.asset.skills_items", fallback: "%d 个", totalSkills) + " (" + dynamicText(zh: "用户自定义", en: "user-defined") + ")",
                        theme: .emerald
                    )

                    // Token 消耗
                    AssetRow(
                        icon: "dollarsign.circle.fill",
                        label: dynamicText(zh: "🪙 Token 消耗", en: "Token Usage"),
                        value: dynamicText(zh: "— (待接入)", en: "— (coming soon)"),
                        theme: .slate
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .premiumCard(theme: .slate)
        }
    }
}

// MARK: - 积木圆角卡片行

struct AssetRow: View {
    let icon: String
    let label: String
    let value: String
    let theme: DesignSystem.GradientTheme

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.gradient.opacity(0.12))
                    .frame(width: 24, height: 24)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.gradient)
            }

            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.secondary.opacity(0.04)) // 积木式微背景
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 6)
    }
}

// MARK: - 精美原生系统隔离状态监控卡片 (Cyber-Glass Widget)

struct SystemStatusCard: View {
    @Environment(HelperClient.self) private var helperClient

    // 动态获取 macOS 物理系统版本
    private var osVersionString: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    // 动态获取真实芯片/CPU型号
    private var chipModel: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var machine = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &machine, &size, nil, 0)
            let brand = String(cString: machine).trimmingCharacters(in: .whitespacesAndNewlines)
            if !brand.isEmpty {
                return brand.replacingOccurrences(of: "Apple ", with: "")
                            .replacingOccurrences(of: "Intel(R) Core(TM) ", with: "")
                            .replacingOccurrences(of: "CPU", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 兜底路径获取 Apple Silicon
        var modelSize = 0
        sysctlbyname("hw.model", nil, &modelSize, nil, 0)
        if modelSize > 0 {
            var model = [CChar](repeating: 0, count: modelSize)
            sysctlbyname("hw.model", &model, &modelSize, nil, 0)
            let modelStr = String(cString: model)
            if modelStr.contains("Mac") {
                return "Apple Silicon"
            }
            return modelStr
        }
        return "Apple Silicon"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                // 1. 金色 Apple M芯片 或 安全端守护极客质感图标
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DesignSystem.GradientTheme.teal.gradient.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.GradientTheme.teal.gradient)
                }

                Spacer()

                // 2. 右侧动态大字硬件型号
                VStack(alignment: .trailing, spacing: 1) {
                    Text(chipModel)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(osVersionString)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // 3. 卡片标题
            Text(dynamicText(zh: "系统运行状态", en: "System Status"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            // 4. XPC 守护进程联接状态呼吸灯
            HStack(spacing: 5) {
                Circle()
                    .fill(helperClient.isConnected ? Color.green : Color.red)
                    .frame(width: 5, height: 5)

                Text(helperClient.isConnected
                     ? dynamicText(zh: "XPC 守护: 已联接", en: "XPC Helper: Active")
                     : dynamicText(zh: "XPC 守护: 未运行", en: "XPC Helper: Inactive"))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            // 5. XPC 核心安全通道状态发光水平线
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(helperClient.isConnected ? DesignSystem.GradientTheme.teal.gradient : LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing))
                        .frame(width: helperClient.isConnected ? geo.size.width : 0, height: 6)
                        .shadow(color: (helperClient.isConnected ? DesignSystem.GradientTheme.teal.mainColor : .red).opacity(0.4), radius: 3, x: 0, y: 0)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(height: 104) // 严格对齐 104pt
        .premiumCard(theme: .teal)
    }
}

// MARK: - 华丽多语言动态辅助 View 扩展

extension View {
    fileprivate func dynamicText(zh: String, en: String) -> String {
        let selected = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        if selected == "en" {
            return en
        } else if selected == "zh-Hans" {
            return zh
        } else {
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            return preferred.hasPrefix("zh") ? zh : en
        }
    }
}
