// ClawdHome/Views/NetworkPolicyView.swift
// 网络管理页：实时 TCP 连接监控

import SwiftUI

struct NetworkPolicyView: View {
    @Environment(HelperClient.self) private var helperClient
    @State private var connections: [ConnectionInfo] = []
    @State private var filterUsername: String = ""
    @State private var searchText: String = ""
    @State private var showLoopback: Bool = false
    @State private var pollTask: Task<Void, Never>?

    private var filtered: [ConnectionInfo] {
        connections.filter { c in
            (showLoopback || !c.isLoopback) &&
            (filterUsername.isEmpty || c.username == filterUsername) &&
            (searchText.isEmpty ||
             c.remoteAddr.localizedCaseInsensitiveContains(searchText) ||
             (c.remoteHost ?? "").localizedCaseInsensitiveContains(searchText) ||
             c.processName.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var usernames: [String] {
        Array(Set(connections.map(\.username))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            Divider()

            if !helperClient.isConnected {
                ContentUnavailableView(
                    L10n.k("auto.network_policy_view.helper", fallback: "Helper 未连接"),
                    systemImage: "network.slash",
                    description: Text(L10n.k("auto.network_policy_view.settings_start_helper", fallback: "请前往「设置 → 诊断」安装或启动 Helper"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                NetworkRadarPlaceholder(
                    title: connections.isEmpty ? L10n.k("auto.network_policy_view.no", fallback: "暂无活跃连接") : L10n.k("auto.network_policy_view.no_matching_results", fallback: "无匹配结果"),
                    description: connections.isEmpty
                        ? L10n.k("auto.network_policy_view.gateway_has_no_tcp_connections_when_idle_connections", fallback: "Gateway 空闲时无 TCP 连接，发起请求后会出现。")
                        : L10n.k("auto.network_policy_view.text_757335e7e2", fallback: "尝试清除筛选条件。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                connectionTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(L10n.k("auto.network_policy_view.network", fallback: "网络管理"))
        .task {
            pollTask = Task {
                while !Task.isCancelled {
                    connections = await helperClient.getConnections()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    // MARK: - 筛选栏

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker(L10n.k("auto.network_policy_view.shrimp", fallback: "虾"), selection: $filterUsername) {
                Text(L10n.k("auto.network_policy_view.all_shrimps", fallback: "全部虾")).tag("")
                ForEach(usernames, id: \.self) { u in
                    Text("@\(u)").tag(u)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 140)

            Spacer()

            // 搜索框
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(L10n.k("auto.network_policy_view.searchaddress_process", fallback: "搜索地址/进程"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.8)
            )
            .frame(maxWidth: 220)

            Toggle(isOn: $showLoopback) {
                Text("Loopback")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(L10n.k("auto.network_policy_view.local_127_x_x_x_1", fallback: "显示本地回环连接（127.x.x.x / ::1）"))

            Text(L10n.f("views.network_policy_view.text_413b5432", fallback: "%@ 条", String(describing: filtered.count)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - 连接表格

    private var connectionTable: some View {
        Table(filtered) {
            TableColumn(L10n.k("auto.network_policy_view.shrimp", fallback: "虾")) { c in
                Text("@\(c.username)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn(L10n.k("auto.network_policy_view.processes", fallback: "进程")) { c in
                Text(c.processName)
                    .font(.system(.caption2, design: .monospaced))
            }
            .width(100)

            TableColumn(L10n.k("auto.network_policy_view.address", fallback: "远端地址")) { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.remoteAddr)
                        .font(.system(.caption2, design: .monospaced))
                    if let host = c.remoteHost {
                        Text(host)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 140, ideal: 200)

            TableColumn(L10n.k("auto.network_policy_view.status", fallback: "状态")) { c in
                stateTag(c.state)
            }
            .width(110)

            TableColumn(L10n.k("auto.network_policy_view.text_890bba7fe6", fallback: "↓ 速率")) { c in
                Text(FormatUtils.formatBps(c.rateIn))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(c.rateIn > 0 ? .primary : .secondary)
            }
            .width(75)

            TableColumn(L10n.k("auto.network_policy_view.text_497ca0f2fe", fallback: "↑ 速率")) { c in
                Text(FormatUtils.formatBps(c.rateOut))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(c.rateOut > 0 ? .primary : .secondary)
            }
            .width(75)

            TableColumn(L10n.k("auto.network_policy_view.text_a8addf6f21", fallback: "累计收/发")) { c in
                let rx = UInt64(max(0, c.bytesIn))
                let tx = UInt64(max(0, c.bytesOut))
                HStack(spacing: 4) {
                    Text("↓\(FormatUtils.formatTotalBytes(rx))")
                        .foregroundStyle(rx > 0 ? .primary : .secondary)
                    Text("↑\(FormatUtils.formatTotalBytes(tx))")
                        .foregroundStyle(tx > 0 ? .primary : .secondary)
                }
                .font(.system(.caption2, design: .monospaced))
            }
            .width(150)
        }
        .tableStyle(.inset)
    }

    // MARK: - 状态标签

    @ViewBuilder
    private func stateTag(_ state: String) -> some View {
        let color: Color = switch state {
        case "ESTABLISHED":                              .green
        case "CLOSE_WAIT", "FIN_WAIT_1", "FIN_WAIT_2",
             "CLOSING", "LAST_ACK":                     .orange
        case "TIME_WAIT":                               .yellow
        case "LISTEN":                                  .blue
        default:                                        .secondary
        }
        
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
            Text(state)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(color.opacity(0.24), lineWidth: 0.7)
        )
    }
}

// MARK: - 高级脉冲扫描雷达网络占位图

struct NetworkRadarPlaceholder: View {
    let title: String
    let description: String
    
    @State private var rotationAngle: Double = 0
    @State private var waveScale1: CGFloat = 1.0
    @State private var waveOpacity1: Double = 0.5
    @State private var waveScale2: CGFloat = 1.0
    @State private var waveOpacity2: Double = 0.5

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                // 1. 同心圆雷达波圈
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .stroke(Color.blue.opacity(0.06 * Double(4 - i)), lineWidth: 1.0)
                        .frame(width: CGFloat(i * 64), height: CGFloat(i * 64))
                }
                
                // 2. 极客十字网格线
                Path { path in
                    path.move(to: CGPoint(x: 96, y: 0))
                    path.addLine(to: CGPoint(x: 96, y: 192))
                    path.move(to: CGPoint(x: 0, y: 96))
                    path.addLine(to: CGPoint(x: 192, y: 96))
                }
                .stroke(style: StrokeStyle(lineWidth: 0.8, lineCap: .round, dash: [4, 4]))
                .foregroundStyle(Color.blue.opacity(0.12))
                .frame(width: 192, height: 192)
                
                // 3. 延迟循环脉冲发光扩散涟漪
                Circle()
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1.5)
                    .scaleEffect(waveScale1)
                    .opacity(waveOpacity1)
                    .frame(width: 48, height: 48)
                    .onAppear {
                        withAnimation(.easeOut(duration: 3.2).repeatForever(autoreverses: false)) {
                            waveScale1 = 3.6
                            waveOpacity1 = 0.0
                        }
                    }
                
                Circle()
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1.0)
                    .scaleEffect(waveScale2)
                    .opacity(waveOpacity2)
                    .frame(width: 48, height: 48)
                    .onAppear {
                        withAnimation(.easeOut(duration: 3.2).repeatForever(autoreverses: false).delay(1.6)) {
                            waveScale2 = 3.6
                            waveOpacity2 = 0.0
                        }
                    }

                // 4. 360度平滑旋转扫描渐变扇形
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [.blue.opacity(0.3), .clear],
                            center: .center,
                            angle: .degrees(0)
                        )
                    )
                    .frame(width: 192, height: 192)
                    .rotationEffect(.degrees(rotationAngle))
                    .onAppear {
                        withAnimation(.linear(duration: 4.5).repeatForever(autoreverses: false)) {
                            rotationAngle = 360
                        }
                    }
                
                // 5. 极客发光核
                ZStack {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                    Circle()
                        .stroke(Color.blue, lineWidth: 1.5)
                        .scaleEffect(1.5)
                        .opacity(0.4)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 200, height: 200)
            
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.system(.subheadline))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(.vertical, 40)
    }
}
