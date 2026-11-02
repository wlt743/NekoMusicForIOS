import SwiftUI

/// 切换接口服务器后，把整棵界面树重建一遍。
///
/// iOS 没有「重启应用」的公开接口，但把根视图的 identity 换掉，
/// 所有 @StateObject / .task 都会重新走一遍，等价于软重启；
/// 再顺手清掉播放器状态与缓存，避免看到上一个服务器的内容。
@MainActor
final class AppReloader: ObservableObject {
    static let shared = AppReloader()

    @Published private(set) var token: Int = 0

    private init() {}

    func reload() {
        let player = AudioPlayerService.shared
        player.pause()
        CacheService.clear()
        URLCache.shared.removeAllCachedResponses()
        token &+= 1
        NSLog("[NekoReload] 界面已重建 token=%d", token)
    }
}
