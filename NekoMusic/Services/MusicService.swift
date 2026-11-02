import Foundation

/// 音乐详情（新接口把歌词直接放在 info 里返回）
struct MusicInfo {
    let music: Music
    let lyrics: String
    let maxQuality: String?
}

class MusicService {
    static let shared = MusicService()

    private let network = NetworkService.shared

    private init() {}

    // MARK: - Search

    func searchMusic(query: String) async throws -> [Music] {
        let data = try await network.rawPost(
            url: APIConfig.musicSearchURL(),
            json: ["query": query]
        )
        return try parseMusicList(data: data, dataKey: "results", errorHint: "搜索失败", allowEmpty: true)
    }

    // MARK: - Ranking

    func getRanking(limit: Int = 200) async throws -> [Music] {
        let data = try await network.rawGet(url: APIConfig.musicRankingURL())
        return try parseMusicList(data: data, dataKey: "data", errorHint: "获取排行榜失败")
    }

    // MARK: - Latest

    func getLatest(limit: Int = 300) async throws -> [Music] {
        let data = try await network.rawGet(url: APIConfig.musicLatestURL())
        return try parseMusicList(data: data, dataKey: "data", errorHint: "获取最新音乐失败")
    }

    // MARK: - 每日推荐

    /// 服务端按用户收藏风格返回的当日推荐（东八区 00:00 更新，不含已收藏曲目）。
    /// 返回项只有 `musicId` 等元数据，没有 `id` 字段，需要手工映射。
    func getDailyRecommendations(token: String) async throws -> [Music] {
        let data = try await network.rawGet(url: APIConfig.dailyRecommendationsURL(), token: token)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.serverError("获取每日推荐失败")
        }
        if let success = json["success"] as? Bool, !success {
            throw NetworkError.serverError(json["message"] as? String ?? "获取每日推荐失败")
        }
        guard let list = json["data"] as? [[String: Any]] else { return [] }

        return list.compactMap { item in
            guard let musicId = item["musicId"] as? Int else { return nil }
            return Music(
                id: musicId,
                title: item["title"] as? String ?? "未知歌曲",
                artist: item["artist"] as? String ?? "未知歌手",
                album: item["album"] as? String ?? "",
                duration: 0,
                filePath: nil,
                coverFilePath: item["cover"] as? String,
                uploadUserId: nil,
                createdAt: nil,
                playCount: nil,
                lrc: nil
            )
        }
    }

    // MARK: - Music Info / Lyrics

    func getMusicInfo(id: Int) async throws -> MusicInfo {
        let data = try await network.rawGet(url: APIConfig.musicInfoURL(id: id))
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let success = json["success"] as? Bool, success,
            let musicData = json["data"] as? [String: Any],
            let music = Music.fromJSON(musicData)
        else {
            throw NetworkError.serverError(NetworkService.message(from: data) ?? "获取音乐信息失败")
        }
        return MusicInfo(
            music: music,
            lyrics: musicData["lyrics"] as? String ?? "",
            maxQuality: musicData["maxQuality"] as? String
        )
    }

    func getLyrics(musicId: Int) async throws -> String {
        try await getMusicInfo(id: musicId).lyrics
    }

    // MARK: - Audio URL

    /// 新接口不再 302 到音频，而是返回 `data.url`（站内媒体相对地址），
    /// 客户端需要再对这一地址发起普通 GET。
    func resolveAudioURL(musicId: Int, quality: String = "hq") async throws -> URL {
        let data = try await network.rawGet(url: APIConfig.musicFileURL(id: musicId, quality: quality))
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let success = json["success"] as? Bool, success,
            let payload = json["data"] as? [String: Any],
            let path = payload["url"] as? String,
            let url = URL(string: APIConfig.buildFullURL(path: path))
        else {
            throw NetworkError.serverError(NetworkService.message(from: data) ?? "无法获取播放地址")
        }
        return url
    }

    // MARK: - Parse Response

    private func parseMusicList(data: Data, dataKey: String, errorHint: String, allowEmpty: Bool = false) throws -> [Music] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return Music.fromJSONArray(array)
            }
            throw NetworkError.serverError(errorHint)
        }

        let isSuccess: Bool
        if let b = json["success"] as? Bool {
            isSuccess = b
        } else if let i = json["success"] as? Int {
            isSuccess = i != 0
        } else {
            isSuccess = true
        }

        if !isSuccess {
            if allowEmpty { return [] }
            let message = json["message"] as? String ?? errorHint
            throw NetworkError.serverError(message)
        }

        let musicArray: [[String: Any]]?
        if let arr = json[dataKey] as? [[String: Any]] {
            musicArray = arr
        } else if dataKey != "data", let arr = json["data"] as? [[String: Any]] {
            musicArray = arr
        } else {
            musicArray = nil
        }

        guard let array = musicArray else { return [] }
        return Music.fromJSONArray(array)
    }

    // MARK: - URLs

    func getMusicFileURL(musicId: Int) -> URL? {
        URL(string: APIConfig.musicFileURL(id: musicId))
    }

    func getMusicCoverURL(music: Music) -> URL? {
        let urlString = APIConfig.buildMusicCoverURL(musicId: music.id, coverFilePath: music.coverFilePath)
        return URL(string: urlString)
    }
}
