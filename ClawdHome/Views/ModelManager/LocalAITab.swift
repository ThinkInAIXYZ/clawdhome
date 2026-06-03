// ClawdHome/Views/ModelManager/LocalAITab.swift
// 本地 AI 服务管理：omlx LLM + mlx-audio TTS/STT（Phase 2）

import SwiftUI

struct LocalAITab: View {
    @Environment(HelperClient.self) private var helperClient

    @State private var llmStatus = LocalServiceStatus(
        isInstalled: false, isRunning: false, pid: -1, currentModelId: "", port: 18800)
    @State private var isStarting = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                omlxStatusSection
                // Phase 2: audioSection
            }
            .padding(16)
        }
        .task { await refreshStatus() }
    }

    // MARK: - omlx 状态卡

    private var omlxStatusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "cpu.fill")
                    .font(.title2)
                    .foregroundStyle(LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.k("local_aitab.omlx.title", fallback: "本地推理引擎 omlx"))
                        .font(.headline)
                    Text(L10n.k("local_aitab.omlx.subtitle", fallback: "Apple Silicon 平台极佳能效与性能的本地 LLM 推理引擎"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if llmStatus.isInstalled {
                    statusBadge
                }
            }
            
            Divider()
            
            // 推荐理由与说明
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.k("local_aitab.omlx.why_title", fallback: "为什么推荐 omlx？"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                
                Text(L10n.k("local_aitab.omlx.why_desc", fallback: "omlx 是专为 macOS 深度优化的超轻量、低功耗本地大模型推理引擎。相较于传统工具，它能以极低的内存与电量消耗在后台流畅运行，是笔记本日常使用的不二之选。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                
                Button {
                    if let url = URL(string: "https://github.com/jundot/omlx") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text(L10n.k("local_aitab.omlx.btn_github", fallback: "访问 omlx GitHub 主页"))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            
            Divider()
            
            // 使用指南
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.k("local_aitab.omlx.guide_title", fallback: "快速启动指南"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                VStack(alignment: .leading, spacing: 8) {
                    guideStep(
                        step: "1",
                        title: L10n.k("local_aitab.omlx.step1_title", fallback: "安装引擎"),
                        description: L10n.k("local_aitab.omlx.step1_desc", fallback: "点击上方链接前往 GitHub 下载并安装 omlx（或在终端运行 `brew install jundot/tap/omlx`）。")
                    )
                    guideStep(
                        step: "2",
                        title: L10n.k("local_aitab.omlx.step2_title", fallback: "启动服务"),
                        description: L10n.k("local_aitab.omlx.step2_desc", fallback: "安装完成后在终端运行 `omlx` 命令，服务默认会在 `127.0.0.1:18800` 启动并提供 OpenAI 兼容的 API 接口。")
                    )
                    guideStep(
                        step: "3",
                        title: L10n.k("local_aitab.omlx.step3_title", fallback: "下载与配置"),
                        description: L10n.k("local_aitab.omlx.step3_desc", fallback: "在下方“本地模型库”中下载或放入模型；然后直接在“LLM 模型”设置中登录配置本地模型即可。")
                    )
                }
            }
            
            // 状态与简易控制面板
            if llmStatus.isInstalled {
                Divider()
                
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(llmStatus.isRunning ? L10n.k("local_aitab.omlx.status_connected", fallback: "服务已连接") : L10n.k("local_aitab.omlx.status_disconnected", fallback: "服务未运行"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        if llmStatus.isRunning {
                            Text("\(L10n.k("local_aitab.omlx.api_endpoint", fallback: "本地接口：http://127.0.0.1:"))\(llmStatus.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(L10n.k("local_aitab.omlx.control_tip", fallback: "您可以手动在终端启动，或点击右侧按钮尝试由系统托管拉起。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    if llmStatus.isRunning {
                        Button(action: {
                            Task { await stopLLM() }
                        }) {
                            Text(L10n.k("local_aitab.omlx.btn_stop", fallback: "停止服务"))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: {
                            Task { await startLLM() }
                        }) {
                            Text(isStarting ? L10n.k("local_aitab.omlx.btn_starting", fallback: "启动中...") : L10n.k("local_aitab.omlx.btn_start", fallback: "启动服务"))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isStarting)
                    }
                }
                .padding(.top, 4)
            } else {
                Divider()
                
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(L10n.k("local_aitab.omlx.not_installed_tip", fallback: "💡 检测到系统尚未安装 omlx。手动安装并运行后，系统将自动连接。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        )
    }
    
    private func guideStep(step: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(step)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.blue))
                .padding(.top, 1)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
        }
    }

    private var statusBadge: some View {
        Group {
            if !llmStatus.isInstalled {
                Text(L10n.k("auto.local_aitab.not_installed", fallback: "未安装")).foregroundStyle(.secondary)
            } else if llmStatus.isRunning {
                Label(L10n.k("auto.local_aitab.running", fallback: "运行中"), systemImage: "circle.fill")
                    .foregroundStyle(.green).font(.caption)
            } else {
                Label(L10n.k("auto.local_aitab.stop", fallback: "已停止"), systemImage: "circle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }
        }
    }



    // MARK: - Actions

    private func refreshStatus() async {
        llmStatus = await helperClient.getLocalLLMStatus()
    }


    private func startLLM() async {
        isStarting = true
        errorMessage = nil
        do {
            try await helperClient.startLocalLLM()
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
        isStarting = false
    }

    private func stopLLM() async {
        errorMessage = nil
        do {
            try await helperClient.stopLocalLLM()
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
