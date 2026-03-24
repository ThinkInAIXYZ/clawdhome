// ClawdHome/Views/ModelManager/LocalAITab.swift
// 本地 AI 服务管理：omlx LLM + mlx-audio TTS/STT（Phase 2）

import SwiftUI

struct LocalAITab: View {
    @Environment(HelperClient.self) private var helperClient

    @State private var llmStatus = LocalServiceStatus(
        isInstalled: false, isRunning: false, pid: -1, currentModelId: "", port: 18800)
    @State private var installedModels: [LocalModelInfo] = []
    @State private var isInstalling = false
    @State private var isStarting = false
    @State private var downloadingModelId: String? = nil
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    private let modelDir = "/Users/Shared/ClawdHome/models/omlx"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                omlxStatusSection
                localModelLibrarySection
                // Phase 2: audioSection
            }
            .padding(16)
        }
        .task { await refreshStatus() }
    }

    // MARK: - omlx 状态卡

    private var omlxStatusSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L10n.k("auto.local_aitab.local_omlx", fallback: "本地推理引擎 omlx"), systemImage: "cpu.fill")
                        .font(.headline)
                    Spacer()
                    statusBadge
                }

                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if let suc = successMessage {
                    Text(suc).font(.caption).foregroundStyle(.green)
                }

                HStack(spacing: 8) {
                    if !llmStatus.isInstalled {
                        Button(isInstalling ? L10n.k("auto.local_aitab.text_b2c6913616", fallback: "安装中…") : L10n.k("auto.local_aitab.omlx", fallback: "一键安装 omlx")) {
                            Task { await installOmlx() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isInstalling)
                    } else if llmStatus.isRunning {
                        Text(L10n.f("views.model_manager.local_aitab.text_f8186bb5", fallback: "端口 %@", String(describing: llmStatus.port))).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.k("auto.local_aitab.stop", fallback: "停止")) { Task { await stopLLM() } }
                            .buttonStyle(.bordered)
                    } else {
                        Button(isStarting ? L10n.k("auto.local_aitab.start", fallback: "启动中…") : L10n.k("auto.local_aitab.start", fallback: "启动服务")) {
                            Task { await startLLM() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isStarting)
                    }
                }
            }
            .padding(4)
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

    // MARK: - 模型库

    private var localModelLibrarySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.k("auto.local_aitab.localmodels", fallback: "本地模型库")).font(.headline)
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: modelDir))
                    } label: {
                        Label(L10n.k("auto.local_aitab.opendirectory", fallback: "打开目录"), systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    Button { Task { await refreshStatus() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                // 已安装模型（来自目录扫描）
                ForEach(installedModels) { model in
                    installedModelRow(model)
                }

                // 精选未安装模型
                let notInstalled = curatedLLMModels.filter { curated in
                    !installedModels.contains { $0.id == curated.id }
                }
                if !notInstalled.isEmpty {
                    if !installedModels.isEmpty { Divider() }
                    Text(L10n.k("auto.local_aitab.downloadable_curated", fallback: "可下载（精选）")).font(.caption).foregroundStyle(.secondary)
                    ForEach(notInstalled) { curated in
                        curatedModelRow(curated)
                    }
                }

                if installedModels.isEmpty && curatedLLMModels.isEmpty {
                    Text(L10n.k("auto.local_aitab.modelsdirectory_modelsdirectory", fallback: "模型目录为空，可下载精选模型或手动放入目录"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private func installedModelRow(_ model: LocalModelInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.displayName).font(.callout)
                    if model.isManual {
                        Text(L10n.k("auto.local_aitab.manual", fallback: "手动")).font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                Text(String(format: "%.1f GB", model.sizeGB))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await deleteModel(model.id) }
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func curatedModelRow(_ curated: CuratedLocalModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(curated.displayName).font(.callout)
                Text(
                    L10n.f(
                        "views.model_manager.local_aitab.curated_size",
                        fallback: "%@ · 约 %@ GB",
                        curated.description,
                        String(format: "%.1f", curated.estimatedSizeGB)
                    )
                )
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if downloadingModelId == curated.id {
                ProgressView().scaleEffect(0.7)
            } else {
                Button(L10n.k("auto.local_aitab.download", fallback: "下载")) {
                    Task { await downloadModel(curated.id) }
                }
                .buttonStyle(.bordered)
                .disabled(downloadingModelId != nil)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func refreshStatus() async {
        llmStatus = await helperClient.getLocalLLMStatus()
        installedModels = await helperClient.listLocalModels()
    }

    private func installOmlx() async {
        isInstalling = true
        errorMessage = nil
        successMessage = nil
        do {
            try await helperClient.installOmlx()
            successMessage = L10n.k("auto.local_aitab.omlx", fallback: "omlx 安装成功")
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
        isInstalling = false
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

    private func downloadModel(_ modelId: String) async {
        downloadingModelId = modelId
        errorMessage = nil
        do {
            try await helperClient.downloadLocalModel(modelId)
            await refreshStatus()
        } catch {
            errorMessage = L10n.f("views.model_manager.local_aitab.text_a175d2e4", fallback: "下载失败：%@", String(describing: error.localizedDescription))
        }
        downloadingModelId = nil
    }

    private func deleteModel(_ modelId: String) async {
        errorMessage = nil
        do {
            try await helperClient.deleteLocalModel(modelId)
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
