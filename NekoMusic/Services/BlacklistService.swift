import Foundation

struct BlockedSong: Codable, Identifiable {
    let id: Int
    let title: String
    var artist: String = ""
}

/// 本地歌曲黑名单：后端没有对应接口，存在本机，
/// 拉黑后从各列表过滤掉，播放队列也会跳过。
@MainActor
final class BlacklistService: ObservableObject {
    static let shared = BlacklistService()

    @Published private(set) var songs: [BlockedSong] = []

    private let key = "blacklist.songs"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([BlockedSong].self, from: data) {
            songs = list
        }
    }

    var blockedIDs: Set<Int> {
        Set(songs.map { $0.id })
    }

    func isBlocked(_ id: Int) -> Bool {
        songs.contains { $0.id == id }
    }

    func block(_ music: Music) {
        guard !isBlocked(music.id) else { return }
        songs.insert(BlockedSong(id: music.id, title: music.title, artist: music.artist), at: 0)
        persist()
    }

    func unblock(_ id: Int) {
        songs.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        songs = []
        persist()
    }

    /// 过滤掉黑名单里的歌曲
    func filter(_ list: [Music]) -> [Music] {
        let ids = blockedIDs
        guard !ids.isEmpty else { return list }
        return list.filter { !ids.contains($0.id) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(songs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
