import SwiftUI

struct ModelManagerView: View {
    @Environment(HelperClient.self) private var helperClient
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(ProviderKeychainStore.self) private var keychainStore

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            LLMManagerTab()
                .tabItem { Label(L10n.k("views.model_manager.model_manager_view.llm_models", fallback: "LLM 模型"), systemImage: "cpu.fill") }
                .tag(0)

            TTSManagerTab()
                .tabItem { Label(L10n.k("views.model_manager.model_manager_view.tts_engines", fallback: "TTS 引擎"), systemImage: "waveform") }
                .tag(1)

            VoiceLibraryTab()
                .tabItem { Label(L10n.k("views.model_manager.model_manager_view.voice_library", fallback: "音色库"), systemImage: "mic.fill") }
                .tag(2)

            LocalAITab()
                .tabItem { Label(L10n.k("views.model_manager.model_manager_view.local_ai", fallback: "本地 AI"), systemImage: "desktopcomputer") }
                .tag(3)
                .environment(helperClient)
        }
        .padding(0)
    }
}
