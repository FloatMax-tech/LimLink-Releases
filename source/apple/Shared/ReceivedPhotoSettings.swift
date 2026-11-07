import LimLinkAppSupport
import SwiftUI

struct ReceivedPhotoSettings: View {
    @Bindable private var photos = ReceivedPhotoLibrary.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.text("自动将收到的图片存入相册"), isOn: $photos.automatic)
            Text(L10n.text("需要系统相册授权；接收目录中的原文件会保留。相册副本由系统相册管理。"))
                .font(.caption).foregroundStyle(Palette.secondary)
        }
        .accessibilityIdentifier("settings.photos.automatic")
    }
}
