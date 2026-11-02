import SwiftUI
import UIKit

/// 后端启用了客户端识别，封面 / 头像也要求带客户端头才能取到图片。
/// SwiftUI 的 `AsyncImage` 无法自定义请求头，所以这里用 URLSession 自己加载。
struct RemoteImage<Content: View, Placeholder: View>: View {
    let urlString: String?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    init(
        url: String?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urlString = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let uiImage = uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: urlString) {
            await load()
        }
    }

    private func load() async {
        guard let urlString = urlString, !urlString.isEmpty else {
            uiImage = nil
            return
        }

        if let cached = RemoteImageCache.shared.image(for: urlString) {
            uiImage = cached
            return
        }

        do {
            let data = try await NetworkService.shared.fetchData(url: urlString)
            guard let image = UIImage(data: data) else { return }
            RemoteImageCache.shared.store(image, for: urlString)
            await MainActor.run { self.uiImage = image }
        } catch {
            NSLog("[NekoImage] %@ -> %@", urlString, "\(error)")
        }
    }
}

final class RemoteImageCache {
    static let shared = RemoteImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    func clear() {
        cache.removeAllObjects()
    }
}

extension Notification.Name {
    /// 头像已更新，头像视图需要换一个 URL 重新拉取
    static let avatarDidChange = Notification.Name("NekoMusic.avatarDidChange")
}
