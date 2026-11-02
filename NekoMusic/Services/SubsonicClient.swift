import Foundation

/// Subsonic / Navidrome 兼容客户端。
///
/// 只做「能听歌」所需的最小集合：搜索、最新、随机、专辑曲目、播放地址、封面、歌词。
/// 认证走 URL 参数 u / p（明文），服务端支持 token 认证时可再补。
enum SubsonicClient {

    /// 外部模型只有 Int 型 id，这里维护 hash ↔ 服务器字符串 id 的映射
    private static var idMap: [Int: String] = [:]
    private static var objects: [Int: Music] = [:]
    private static var reverseMap: [String: Int] = [:]
    private static let lock = NSLock()

    // MARK: - 鉴权参数

    private static var authQuery: String {
        let user = ServerConfigSnapshot.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let pass = ServerConfigSnapshot.password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "u=\(user)&p=\(pass)&v=1.16.1&c=NekoMusic&f=json"
    }

    private static func url(_ path: String, extra: String = "") -> URL? {
        let base = ServerConfigSnapshot.baseURL
        guard !base.isEmpty else { return nil }
        let tail = extra.isEmpty ? "" : "&\(extra)"
        return URL(string: "\(base)/rest/\(path)?\(authQuery)\(tail)")
    }

    private static func get(_ path: String, extra: String = "") async throws -> [String: Any] {
        guard let url = url(path, extra: extra) else { throw NekoSourceError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["subsonic-response"] as? [String: Any] else {
            throw NekoSourceError.badResponse
        }
        if let status = response["status"] as? String, status != "ok" {
            let message = (response["error"] as? [String: Any])?["message"] as? String
            throw NekoSourceError.server(message ?? "服务器返回错误")
        }
        return response
    }

    // MARK: - 能力

    static func ping() async -> Bool {
        (try? await get("ping.view")) != nil
    }

    static func latest(limit: Int = 60) async throws -> [Music] {
        let response = try await get("getAlbumList2.view", extra: "type=newest&size=\(max(1, limit / 10))")
        let albums = (response["albumList2"] as? [String: Any])?["album"] as? [[String: Any]] ?? []
        var songs: [Music] = []
        for album in albums.prefix(10) {
            guard let albumID = album["id"] as? String else { continue }
            songs.append(contentsOf: (try? await albumSongs(albumID: albumID)) ?? [])
        }
        return Array(songs.prefix(limit))
    }

    static func random(limit: Int = 200) async throws -> [Music] {
        let response = try await get("getRandomSongs.view", extra: "size=\(limit)")
        let list = (response["randomSongs"] as? [String: Any])?["song"] as? [[String: Any]] ?? []
        return list.compactMap(mapSong)
    }

    static func search(_ query: String, limit: Int = 40) async throws -> [Music] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let response = try await get("search3.view", extra: "query=\(encoded)&songCount=\(limit)")
        let list = (response["searchResult3"] as? [String: Any])?["song"] as? [[String: Any]] ?? []
        return list.compactMap(mapSong)
    }

    static func albumSongs(albumID: String) async throws -> [Music] {
        let encoded = albumID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let response = try await get("getAlbum.view", extra: "id=\(encoded)")
        let list = (response["album"] as? [String: Any])?["song"] as? [[String: Any]] ?? []
        return list.compactMap(mapSong)
    }

    static func streamURL(for music: Music) -> URL? {
        guard let remoteID = remoteID(for: music.id) else { return nil }
        let encoded = remoteID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return url("stream.view", extra: "id=\(encoded)")
    }

    static func coverURL(for music: Music) -> URL? {
        guard let remoteID = remoteID(for: music.id) else { return nil }
        let encoded = remoteID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return url("getCoverArt.view", extra: "id=\(encoded)&size=600")
    }

    static func lyrics(for music: Music) async throws -> String {
        let title = music.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let artist = music.artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let response = try await get("getLyrics.view", extra: "title=\(title)&artist=\(artist)")
        if let lyrics = (response["lyrics"] as? [String: Any])?["value"] as? String {
            return lyrics
        }
        return ""
    }

    // MARK: - 映射

    private static func mapSong(_ raw: [String: Any]) -> Music? {
        guard let remoteID = raw["id"] as? String else { return nil }
        let id = localID(for: remoteID)
        let music = Music(
            id: id,
            title: (raw["title"] as? String) ?? "未知曲目",
            artist: (raw["artist"] as? String) ?? "未知歌手",
            album: (raw["album"] as? String) ?? "",
            duration: (raw["duration"] as? Int) ?? 0,
            filePath: nil,
            coverFilePath: nil,
            uploadUserId: nil,
            createdAt: nil,
            playCount: nil,
            lrc: nil
        )
        lock.lock(); objects[id] = music; lock.unlock()
        return music
    }

    /// 播放/封面需要完整的 Music 对象（要拿原始字符串 id）
    static func music(for id: Int) -> Music? {
        lock.lock(); defer { lock.unlock() }
        return objects[id]
    }

    private static func localID(for remote: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let existing = reverseMap[remote] { return existing }
        var hash: UInt32 = 2166136261
        for byte in remote.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        var value = Int(hash & 0x7FFFFFFF)
        while idMap[value] != nil, idMap[value] != remote {
            value = (value &+ 1) & 0x7FFFFFFF
        }
        idMap[value] = remote
        reverseMap[remote] = value
        return value
    }

    private static func remoteID(for local: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return idMap[local]
    }
}

enum NekoSourceError: LocalizedError {
    case notConfigured
    case badResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置接口服务器"
        case .badResponse: return "服务器返回格式不是 Subsonic 协议"
        case .server(let message): return message
        }
    }
}

/// 网络层用 HapticsService 之外的线程读配置，这里给一份无隔离的快照
enum ServerConfigSnapshot {
    nonisolated(unsafe) static var baseURL: String = ""
    nonisolated(unsafe) static var username: String = ""
    nonisolated(unsafe) static var password: String = ""
    nonisolated(unsafe) static var isSubsonic: Bool = false
}
