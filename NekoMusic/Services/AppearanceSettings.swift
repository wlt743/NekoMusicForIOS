import SwiftUI
import UIKit

// MARK: - 主题色

struct ThemeOption: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color

    static let all: [ThemeOption] = [
        ThemeOption(id: "pink", name: "霓虹粉", color: Color(red: 1.00, green: 0.18, blue: 0.33)),
        ThemeOption(id: "blue", name: "天空蓝", color: Color(red: 0.04, green: 0.52, blue: 1.00)),
        ThemeOption(id: "mint", name: "薄荷绿", color: Color(red: 0.19, green: 0.82, blue: 0.35)),
        ThemeOption(id: "orange", name: "日落橙", color: Color(red: 1.00, green: 0.62, blue: 0.04)),
        ThemeOption(id: "purple", name: "薰衣草", color: Color(red: 0.75, green: 0.35, blue: 0.95)),
        ThemeOption(id: "red", name: "珊瑚红", color: Color(red: 1.00, green: 0.27, blue: 0.23)),
        ThemeOption(id: "graphite", name: "石墨灰", color: Color(red: 0.56, green: 0.56, blue: 0.58)),
    ]

    static let fallback = all[0]
}

// MARK: - 外观设置

/// 主题色与首页壁纸，存在 UserDefaults + Documents。
@MainActor
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    @Published var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: Keys.theme) }
    }

    /// 外观模式：system / light / dark
    @Published var appearanceMode: String {
        didSet { UserDefaults.standard.set(appearanceMode, forKey: Keys.appearanceMode) }
    }

    /// 歌词字号（14–28pt）
    @Published var lyricFontSize: Double {
        didSet { UserDefaults.standard.set(lyricFontSize, forKey: Keys.lyricFontSize) }
    }

    /// 调色盘里选的自定义颜色（十六进制）
    @Published var customColorHex: String {
        didSet { UserDefaults.standard.set(customColorHex, forKey: Keys.customColor) }
    }

    /// 壁纸模糊半径（0–30）
    @Published var wallpaperBlur: Double {
        didSet { UserDefaults.standard.set(wallpaperBlur, forKey: Keys.wallpaperBlur) }
    }

    /// 壁纸遮罩强度（0–0.9），越大越暗/越淡，文字越清晰
    @Published var wallpaperDim: Double {
        didSet { UserDefaults.standard.set(wallpaperDim, forKey: Keys.wallpaperDim) }
    }

    @Published private(set) var wallpaperImage: UIImage?

    private enum Keys {
        static let theme = "appearance.themeID"
        static let appearanceMode = "appearance.mode"
        static let wallpaper = "appearance.wallpaperFile"
        static let lyricFontSize = "appearance.lyricFontSize"
        static let customColor = "appearance.customColor"
        static let wallpaperBlur = "appearance.wallpaperBlur"
        static let wallpaperDim = "appearance.wallpaperDim"
    }

    static let customThemeID = "custom"

    private var wallpaperFileName: String? {
        get { UserDefaults.standard.string(forKey: Keys.wallpaper) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.wallpaper) }
    }

    /// 给 preferredColorScheme 用；system 返回 nil 表示跟随系统
    var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var theme: ThemeOption {
        ThemeOption.all.first { $0.id == themeID } ?? .fallback
    }

    var customColor: Color {
        Color(hex: customColorHex) ?? ThemeOption.fallback.color
    }

    var tintColor: Color {
        themeID == Self.customThemeID ? customColor : theme.color
    }

    /// 调色盘选色：转成十六进制保存，并自动切到「自定义」
    func setCustomColor(_ color: Color) {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        customColorHex = String(
            format: "#%02X%02X%02X",
            Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255))
        )
        themeID = Self.customThemeID
    }

    private init() {
        themeID = UserDefaults.standard.string(forKey: Keys.theme) ?? ThemeOption.fallback.id
        appearanceMode = UserDefaults.standard.string(forKey: Keys.appearanceMode) ?? "system"
        let savedSize = UserDefaults.standard.double(forKey: Keys.lyricFontSize)
        lyricFontSize = savedSize >= 14 ? savedSize : 19
        customColorHex = UserDefaults.standard.string(forKey: Keys.customColor) ?? "#FF2D55"

        let savedBlur = UserDefaults.standard.double(forKey: Keys.wallpaperBlur)
        wallpaperBlur = savedBlur > 0 ? savedBlur : 2
        let savedDim = UserDefaults.standard.double(forKey: Keys.wallpaperDim)
        wallpaperDim = savedDim > 0 ? savedDim : 0.45
        wallpaperImage = Self.loadWallpaper(named: UserDefaults.standard.string(forKey: Keys.wallpaper))
    }

    // MARK: 壁纸

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func loadWallpaper(named name: String?) -> UIImage? {
        guard let name = name else { return nil }
        let url = documentsDirectory.appendingPathComponent(name)
        return UIImage(contentsOfFile: url.path)
    }

    func setWallpaper(_ image: UIImage) {
        // 控制体积：长边最多 2000px
        let prepared = Self.downscaled(image, maxSide: 2000)
        guard let data = prepared.jpegData(compressionQuality: 0.9) else { return }

        let name = "home-wallpaper.jpg"
        let url = Self.documentsDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            wallpaperFileName = name
            wallpaperImage = prepared
        } catch {
            NSLog("[NekoAppearance] wallpaper save failed: %@", "\(error)")
        }
    }

    func removeWallpaper() {
        if let name = wallpaperFileName {
            try? FileManager.default.removeItem(at: Self.documentsDirectory.appendingPathComponent(name))
        }
        wallpaperFileName = nil
        wallpaperImage = nil
    }

    private static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1, maxSide / max(size.width, size.height))
        guard scale < 1 else { return image }

        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}


extension Color {
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt64(text, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
