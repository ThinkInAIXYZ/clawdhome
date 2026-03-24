import Foundation

enum TTSEngineType: String, Codable, CaseIterable {
    case f5tts      = "f5tts"
    case elevenlabs = "elevenlabs"
    case fishAudio  = "fishAudio"

    var displayName: String {
        switch self {
        case .f5tts:      return L10n.k("models.voice_profile.f5_tts_mlx_local", fallback: "F5-TTS MLX（本地）")
        case .elevenlabs: return L10n.k("models.voice_profile.elevenlabs_cloud", fallback: "ElevenLabs（云端）")
        case .fishAudio:  return L10n.k("models.voice_profile.fish_audio_cloud", fallback: "Fish Audio（云端）")
        }
    }
}

struct VoiceProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var engine: TTSEngineType
    var referenceAudioPath: String?  // F5-TTS 用：参考音频路径
    var externalVoiceId: String?     // ElevenLabs / Fish Audio 用：Voice ID
    var isGlobalDefault: Bool = false
}
