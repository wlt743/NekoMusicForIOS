import ActivityKit
import Foundation

/// 锁屏实时活动的数据契约（主 App 与 Widget Extension 共用）
struct LyricActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var artworkData: Data?
        var previous: String
        var current: String
        var next: String
        var isPlaying: Bool
    }

    var title: String
    var artist: String
}
