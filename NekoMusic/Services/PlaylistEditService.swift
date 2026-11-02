import Foundation

/// 歌单编辑（改名 / 改描述）
final class PlaylistEditService {
    static let shared = PlaylistEditService()

    private let network = NetworkService.shared

    private init() {}

    func update(playlistId: Int, name: String, description: String?, token: String) async throws -> PlaylistInfo? {
        struct Body: Encodable {
            let id: Int
            let name: String
            let description: String?
        }

        let response: PlaylistUpdateResponse = try await network.post(
            url: APIConfig.playlistUpdateURL(),
            body: Body(id: playlistId, name: name, description: description),
            token: token
        )

        guard response.success else {
            throw NetworkError.serverError(response.message ?? "更新歌单失败")
        }
        return response.playlist
    }
}
