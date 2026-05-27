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

                // ClawdHome 概览
                DashboardSection(title: L10n.k("dashboard.section.clawdhome_overview", fallback: "ClawdHome 概览"), icon: "desktopcomputer") {
                    MachineStatsGrid(
                        stats: pool.snapshot?.machine,
                        history: pool.machineHistory,
                        netRateHistory: pool.netRateHistory,
                        shrimps: pool.snapshot?.shrimps ?? []
                    )
                }

                Divider()

                // 虾塘概览
                DashboardSection(title: L10n.k("dashboard.section.shrimp_pool_overview", fallback: "虾塘概览"), icon: "network") {
                    ShrimpNetworkSection(
                        shrimps: pool.snapshot?.shrimps ?? [],
                        total: pool.snapshot?.totalShrimpCount ?? 0,
                        running: pool.snapshot?.runningShrimpCount ?? 0
                    )
                }

                Divider()

                // 资产概览
                DashboardSection(title: L10n.k("dashboard.section.asset_overview", fallback: "资产概览"), icon: "shippingbox") {
                    AssetOverviewSection(shrimps: pool.snapshot?.shrimps ?? [])
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
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
    }
}

// MARK: - 本机概览

struct MachineStatsGrid: View {
    let stats: MachineStats?
    var history: [MachineStats] = []
    var netRateHistory: [(inBps: Double, outBps: Double)] = []
    var shrimps: [ShrimpNetStats] = []

    private var currentNetIn:  Double { shrimps.reduce(0.0) { $0 + $1.netRateInBps } }
    private var currentNetOut: Double { shrimps.reduce(0.0) { $0 + $1.netRateOutBps } }
    private var totalNetIn:    UInt64 { shrimps.reduce(0) { $0 + $1.netBytesIn } }
    private var totalNetOut:   UInt64 { shrimps.reduce(0) { $0 + $1.netBytesOut } }
    /// 波形用总吞吐（in + out），range 取历史最大值动态缩放
    private var netTotalSamples: [Double] {
        netRateHistory.map { $0.inBps + $0.outBps }
    }
    private var netRange: ClosedRange<Double> {
        let peak = netTotalSamples.max() ?? 0
        return 0...(max(peak, 1024))   // 最低 1 KB/s 刻度，避免空图
    }

    @State private var expanded: String? = nil

    /// 所有卡片数据（统一管理，方便展开时复用）
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
                icon: "gpu", theme: .purple,
                samples: history.compactMap { $0.gpuPercent },
                range: 0...100
            ))
        }
        result.append(CardData(
            title: L10n.k("common.resource.memory", fallback: "内存"),
            value: stats.map { String(format: "%.0f/%.0f GB",
                $0.memUsedMB / 1024, $0.memTotalMB / 1024) } ?? "—",
            icon: "memorychip", theme: .teal,
            samples: history.map { $0.memUsedMB / max($0.memTotalMB, 1) * 100 },
            range: 0...100
        ))
        result.append(CardData(
            title: L10n.k("common.resource.network", fallback: "网络"),
            value: "↓ \(FormatUtils.formatBps(currentNetIn))",
            value2: "↑ \(FormatUtils.formatBps(currentNetOut))",
            cumulativeIn: FormatUtils.formatTotalBytes(totalNetIn),
            cumulativeOut: FormatUtils.formatTotalBytes(totalNetOut),
            icon: "arrow.up.arrow.down", theme: .emerald,
            samples: netTotalSamples,
            range: netRange
        ))
        result.append(CardData(
            title: L10n.k("common.resource.disk", fallback: "磁盘"),
            value: stats.map { String(format: "%.0f/%.0f GB",
                $0.diskUsedGB, $0.diskTotalGB) } ?? "—",
            icon: "internaldrive", theme: .slate,
            samples: [],
            range: 0...100
        ))
        if let temp = stats?.cpuTempCelsius {
            result.append(CardData(
                title: L10n.k("common.resource.temperature", fallback: "温度"),
                value: String(format: "%.0f°C", temp),
                icon: "thermometer.medium", theme: .orange,
                samples: history.compactMap { $0.cpuTempCelsius },
                range: 0...110
            ))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 8) {
            // 展开的大图
            if let exp = expanded, let card = cards.first(where: { $0.title == exp }),
               !card.samples.isEmpty {
                ExpandedChartCard(card: card) {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded = nil }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // 卡片行
            Grid(horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    ForEach(cards, id: \.title) { card in
                        SparklineStatCard(
                            title: card.title,
                            value: card.value,
                            value2: card.value2,
                            icon: card.icon,
                            theme: card.theme,
                            samples: Array(card.samples.suffix(kSmallCardPoints)),
                            range: card.range,
                            maxPoints: kSmallCardPoints
                        )
                        .opacity(expanded == card.title ? 0.5 : 1)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expanded = expanded == card.title ? nil : card.title
                            }
                        }
                    }
                }
            }
        }
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
                // 当前速率
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
                // 累计流量（仅网络卡片有此字段）
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

// 带迷你波形的统计卡片 — 统一高度
struct SparklineStatCard: View {
    let title: String
    let value: String
    var value2: String? = nil
    let icon: String
    let theme: DesignSystem.GradientTheme
    let samples: [Double]
    let range: ClosedRange<Double>
    var maxPoints: Int = kHistoryMax

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption2).foregroundStyle(theme.mainColor).frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let value2 {
                    Text(value2)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(title).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !samples.isEmpty {
                MiniSparkline(samples: samples, range: range, color: theme.mainColor, maxPoints: maxPoints)
                    .frame(height: 20)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .premiumCard(theme: theme)
    }
}

// 折线波形图
struct MiniSparkline: View {
    let samples: [Double]
    let range: ClosedRange<Double>
    let color: Color
    var maxPoints: Int = kHistoryMax   // X 轴固定域宽

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
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.linear)
                
                AreaMark(
                    x: .value("t", s.id),
                    y: .value("v", s.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.18), color.opacity(0.01)],
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

// MARK: - 虾池概览

struct ShrimpNetworkSection: View {
    let shrimps: [ShrimpNetStats]
    let total: Int
    let running: Int

    @Environment(GatewayHub.self) private var gatewayHub
    private var activeShrimps: [ShrimpNetStats] { shrimps.filter { $0.cpuPercent != nil || $0.memRssMB != nil } }
    private var totalCPU: Double { activeShrimps.compactMap(\.cpuPercent).reduce(0, +) }
    private var totalMemMB: Double { activeShrimps.compactMap(\.memRssMB).reduce(0, +) }
    private var totalStorage: Int64 { shrimps.reduce(0) { $0 + max(0, $1.openclawDirBytes) } }
    private var totalNetIn: UInt64 { shrimps.reduce(0) { $0 + $1.netBytesIn } }
    private var totalNetOut: UInt64 { shrimps.reduce(0) { $0 + $1.netBytesOut } }
    private var currentNetInBps: Double { shrimps.reduce(0) { $0 + $1.netRateInBps } }
    private var currentNetOutBps: Double { shrimps.reduce(0) { $0 + $1.netRateOutBps } }
    private var totalSkills: Int { shrimps.reduce(0) { $0 + $1.skillCount } }
    private var topStorageShrimps: [ShrimpNetStats] {
        shrimps
            .filter { $0.openclawDirBytes > 0 }
            .sorted { $0.openclawDirBytes > $1.openclawDirBytes }
            .prefix(3)
            .map { $0 }
    }

    private var memLabel: String {
        totalMemMB >= 1024 ? String(format: "%.1f GB", totalMemMB / 1024) : String(format: "%.0f MB", totalMemMB)
    }

    private var cpuLabel: String { String(format: "%.0f%%", totalCPU) }
    private var avgStorageLabel: String {
        guard total > 0 else { return "—" }
        return FormatUtils.formatBytes(totalStorage / Int64(total))
    }

    private var readyCount: Int { shrimps.filter { readiness(for: $0) == .ready }.count }
    private var startingCount: Int { shrimps.filter { readiness(for: $0) == .starting }.count }
    private var zombieCount: Int { shrimps.filter { readiness(for: $0) == .zombie }.count }

    private func readiness(for shrimp: ShrimpNetStats) -> GatewayReadiness {
        if let state = gatewayHub.readinessMap[shrimp.username] { return state }
        return (shrimp.isRunning ?? false) ? .ready : .stopped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shrimps.isEmpty {
                Text(L10n.k("dashboard.no_shrimps", fallback: "暂无虾"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                HStack(spacing: 8) {
                    ShrimpStatusPill(title: L10n.k("dashboard.shrimp_status.running", fallback: "运行"), value: "\(running)/\(total)", tint: running > 0 ? .green : .secondary)
                    ShrimpStatusPill(title: L10n.k("dashboard.shrimp_status.ready", fallback: "就绪"), value: "\(readyCount)", tint: .green)
                    ShrimpStatusPill(title: L10n.k("dashboard.shrimp_status.starting", fallback: "启动中"), value: "\(startingCount)", tint: .yellow)
                    ShrimpStatusPill(title: L10n.k("dashboard.shrimp_status.anomaly", fallback: "异常"), value: "\(zombieCount)", tint: zombieCount > 0 ? .red : .secondary)
                }
                .font(.caption)

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ShrimpOverviewCard(
                        title: L10n.k("dashboard.card.cpu_summary", fallback: "CPU 汇总"),
                        value: cpuLabel,
                        subtitle: L10n.f("dashboard.card.active_shrimps", fallback: "活跃 %d 只虾", activeShrimps.count),
                        icon: "cpu",
                        theme: .blue
                    )
                    ShrimpOverviewCard(
                        title: L10n.k("dashboard.card.memory_summary", fallback: "内存汇总"),
                        value: memLabel,
                        subtitle: L10n.k("dashboard.card.process_memory", fallback: "进程物理内存"),
                        icon: "memorychip",
                        theme: .purple
                    )
                    ShrimpOverviewCard(
                        title: L10n.k("dashboard.card.storage_usage", fallback: "存储占用"),
                        value: FormatUtils.formatBytes(totalStorage),
                        subtitle: L10n.f("dashboard.card.avg_storage", fallback: "平均 %@", avgStorageLabel),
                        icon: "internaldrive",
                        theme: .emerald
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label(L10n.k("dashboard.realtime_traffic", fallback: "实时流量"), systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("↓ \(FormatUtils.formatBps(currentNetInBps))")
                            .font(.system(.caption, design: .monospaced))
                        Text("↑ \(FormatUtils.formatBps(currentNetOutBps))")
                            .font(.system(.caption, design: .monospaced))
                    }
                    HStack(spacing: 8) {
                        Label(L10n.k("dashboard.total_traffic", fallback: "累计流量"), systemImage: "sum")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("↓ \(FormatUtils.formatTotalBytes(totalNetIn))")
                            .font(.system(.caption, design: .monospaced))
                        Text("↑ \(FormatUtils.formatTotalBytes(totalNetOut))")
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(L10n.f("dashboard.skills_count", fallback: "技能 %d", totalSkills))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .premiumCard(theme: .slate)

                if !topStorageShrimps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L10n.k("dashboard.storage_top3", fallback: "存储 Top 3"), systemImage: "externaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(topStorageShrimps, id: \.username) { shrimp in
                            HStack(spacing: 8) {
                                Text("@\(shrimp.username)")
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(FormatUtils.formatBytes(shrimp.openclawDirBytes))
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .premiumCard(theme: .slate)
                }

                Text(L10n.k("dashboard.summary_hint", fallback: "详细资源与连接明细已在「虾塘」中完整提供，仪表盘仅保留汇总。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ShrimpStatusPill: View {
    let title: String
    let value: String
    let tint: Color

    @State private var isBreathing = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            // 呼吸发光圆点
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                
                if tint == .green || tint == .yellow || tint == .red {
                    Circle()
                        .stroke(tint, lineWidth: 2)
                        .scaleEffect(isBreathing ? 2.2 : 1.0)
                        .opacity(isBreathing ? 0.0 : 0.6)
                        .frame(width: 6, height: 6)
                }
            }
            .onAppear {
                if tint == .green || tint == .yellow || tint == .red {
                    withAnimation(
                        .easeInOut(duration: 1.8)
                        .repeatForever(autoreverses: false)
                    ) {
                        isBreathing = true
                    }
                }
            }
            
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint == .secondary ? .secondary : tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(tint.opacity(colorScheme == .dark ? 0.12 : 0.06))
        )
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.24), lineWidth: 0.7)
        )
    }
}

private struct ShrimpOverviewCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let theme: DesignSystem.GradientTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(theme.mainColor)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(theme.mainColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard(theme: theme)
    }
}

// MARK: - 资产概览

private struct AssetMicroTile: View {
    let title: String
    let value: String
    let icon: String
    let theme: DesignSystem.GradientTheme
    
    var body: some View {
        HStack(spacing: 10) {
            // 渐变背板图标
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.gradient.opacity(0.12))
                    .frame(width: 32, height: 32)
                
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.gradient)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.subheadline, design: .monospaced))
                    .fontWeight(.bold)
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .premiumCard(theme: theme)
    }
}

struct AssetOverviewSection: View {
    let shrimps: [ShrimpNetStats]

    private var totalOpenclawBytes: Int64 { shrimps.reduce(0) { $0 + $1.openclawDirBytes } }
    private var totalHomeBytes: Int64 { shrimps.reduce(0) { $0 + $1.homeDirBytes } }
    private var totalMemBytes: Int64 { shrimps.reduce(0) { $0 + $1.memoryDirBytes } }
    private var totalSkills: Int { shrimps.reduce(0) { $0 + $1.skillCount } }

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ], spacing: 10) {
            AssetMicroTile(
                title: L10n.f("dashboard.asset.total_data", fallback: "数据总量（%d 只虾 .openclaw/）", shrimps.count),
                value: FormatUtils.formatBytes(totalOpenclawBytes),
                icon: "internaldrive",
                theme: .blue
            )
            
            if totalHomeBytes > 0 {
                AssetMicroTile(
                    title: L10n.k("dashboard.asset.total_home", fallback: "家目录总量（含所有用户文件）"),
                    value: FormatUtils.formatBytes(totalHomeBytes),
                    icon: "house",
                    theme: .teal
                )
            }
            
            AssetMicroTile(
                title: L10n.f("dashboard.asset.total_memory", fallback: "记忆总量（%d 只虾合计）", shrimps.count),
                value: FormatUtils.formatBytes(totalMemBytes),
                icon: "brain.head.profile",
                theme: .purple
            )
            
            AssetMicroTile(
                title: L10n.k("dashboard.asset.skills_total", fallback: "技能总数（用户自定义）"),
                value: L10n.f("dashboard.asset.skills_items", fallback: "%d 个", totalSkills),
                icon: "sparkles",
                theme: .emerald
            )
            
            AssetMicroTile(
                title: L10n.k("dashboard.asset.token_coming_soon", fallback: "Token 消耗（待接入）"),
                value: "—",
                icon: "bitcoinsign.circle",
                theme: .slate
            )
        }
    }
}
