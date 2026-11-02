import Foundation

/// 收藏歌单：列表 / 收藏 / 取消 / 歌单内音乐
final class FavoritePlaylistService {
    static let shared = FavoritePlaylistService()

    private let network = NetworkService.shared

    private init() {}

    func list(token: String) async throws -> [FavoritePlaylist] {
        let response: FavoritePlaylistListResponse = try await network.get(
            url: APIConfig.favoritePlaylistsURL(),
            token: token
        )
        guard response.success else {
            throw NetworkError.serverError(response.message ?? "获取收藏歌单失败")
        }
        return response.playlists ?? []
    }

    func add(playlistId: Int, token: String) async throws {
        struct Body: Encodable { let playlistId: Int }
        let data = try await network.rawPost(
            url: APIConfig.favoritePlaylistsURL(),
            json: ["playlistId": playlistId],
            token: token
        )
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = json["success"] as? Bool, !success {
            throw NetworkError.serverError(json["message"] as? String ?? "收藏失败或已收藏")
        }
    }

    func remove(playlistId: Int, token: String) async throws {
        let data: Data = try await network.delete(
            url: APIConfig.favoritePlaylistURL(id: playlistId),
            token: token
        )
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = json["success"] as? Bool, !success {
            throw NetworkError.serverError(json["message"] as? String ?? "取消收藏失败")
        }
    }

    func music(playlistId: Int, token: String) async throws -> [FavoritePlaylistMusic] {
        let response: FavoritePlaylistMusicResponse = try await network.get(
            url: APIConfig.favoritePlaylistURL(id: playlistId),
            token: token
        )
        guard response.success else {
            throw NetworkError.serverError(response.message ?? "获取歌单音乐失败")
        }
        return response.music ?? []
    }

    /// 某个歌单是否已收藏（列表里找）
    func isFavorite(playlistId: Int, token: String) async -> Bool {
        (try? await list(token: token).contains { $0.id == playlistId }) ?? false
    }
}
