import SwiftUI
import PhotosUI
import UIKit

struct AppearanceView: View {
    @StateObject private var appearance = AppearanceSettings.shared
    @State private var pickedItem: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 16)]

    var body: some View {
        List {
            Section {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(ThemeOption.all) { theme in
                        Button {
                            appearance.themeID = theme.id
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(theme.color)
                                    .frame(width: 46, height: 46)
                                    .overlay {
                                        if appearance.themeID == theme.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 18, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay {
                                        Circle()
                                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                    }

                                Text(theme.name)
                                    .font(.caption2)
                                    .foregroundStyle(appearance.themeID == theme.id ? Color.primary : Color.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        appearance.themeID = AppearanceSettings.customThemeID
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(appearance.customColor)
                                .frame(width: 46, height: 46)
                                .overlay {
                                    if appearance.themeID == AppearanceSettings.customThemeID {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .overlay {
                                    Circle()
                                        .stroke(
                                            LinearGradient(
                                                colors: [.red, .orange, .yellow, .green, .blue, .purple],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 2
                                        )
                                }

                            Text("自定义")
                                .font(.caption2)
                                .foregroundStyle(appearance.themeID == AppearanceSettings.customThemeID ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)

                ColorPicker(
                    selection: Binding(
                        get: { appearance.customColor },
                        set: { appearance.setCustomColor($0) }
                    ),
                    supportsOpacity: false
                ) {
                    Label("调色盘", systemImage: "eyedropper")
                }
            } header: {
                Text("主题色")
            } footer: {
                Text("影响按钮、链接、进度条等强调色。")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("歌词字号")
                        Spacer()
                        Text("\(Int(appearance.lyricFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(value: $appearance.lyricFontSize, in: 14...28, step: 1)

                    Text("我们都在寻找属于自己的那片星空")
                        .font(.system(size: appearance.lyricFontSize))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                }
                .padding(.vertical, 4)
            } header: {
                Text("歌词")
            } footer: {
                Text("只影响播放页歌词的显示大小，当前行会以高亮白色显示。")
            }

            Section {
                if let image = appearance.wallpaperImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label(appearance.wallpaperImage == nil ? "选择首页壁纸" : "更换壁纸", systemImage: "photo")
                }

                if appearance.wallpaperImage != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("模糊")
                            Spacer()
                            Text("\(Int(appearance.wallpaperBlur))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $appearance.wallpaperBlur, in: 0...30, step: 1)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("遮罩")
                            Spacer()
                            Text("\(Int(appearance.wallpaperDim * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $appearance.wallpaperDim, in: 0...0.9, step: 0.05)
                    }
                    .padding(.vertical, 4)
                }

                if appearance.wallpaperImage != nil {
                    Button(role: .destructive) {
                        appearance.removeWallpaper()
                    } label: {
                        Label("恢复默认背景", systemImage: "arrow.uturn.backward")
                    }
                }
            } header: {
                Text("首页壁纸")
            } footer: {
                Text("壁纸会以毛玻璃质感铺在首页背景，不影响其它页面。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickedItem) { item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    appearance.setWallpaper(image)
                }
                pickedItem = nil
            }
        }
    }
}
