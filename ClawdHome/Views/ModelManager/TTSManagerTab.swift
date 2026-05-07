import SwiftUI

struct TTSManagerTab: View {
    var body: some View {
        ContentUnavailableView(
            L10n.k("models.tts_manager.title", fallback: "TTS 引擎配置"),
            systemImage: "waveform.badge.mic",
            description: Text(L10n.k("models.tts_manager.desc", fallback: "支持 F5-TTS MLX（本地语音克隆）和 ElevenLabs/Fish Audio（云端）\n即将推出"))
        )
    }
}
