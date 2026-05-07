import SwiftUI

struct VoiceLibraryTab: View {
    var body: some View {
        ContentUnavailableView(
            "音色库",
            systemImage: "person.wave.2.fill",
            description: Text("管理语音克隆音色：上传参考音频，全局默认 + 每只虾单独覆盖\n即将推出")
        )
    }
}
