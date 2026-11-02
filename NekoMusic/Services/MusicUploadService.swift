import Foundation

// MARK: - 响应模型

struct UploadedMusicInfo: Codable {
    let id: Int
    let status: String?
    let createdAt: String?
}

struct MusicUploadResponse: Codable {
    let success: Bool
    let message: String?
    let data: UploadedMusicInfo?
}

// MARK: - 服务

/// 用户上传音乐。上传成功后进入待审核状态，审核结果会写站内消息。
final class MusicUploadService {
    static let shared = MusicUploadService()

    private let network = NetworkService.shared

    private init() {}

    struct FilePayload {
        let filename: String
        let mimeType: String
        let data: Data
    }

    /// 我上传且审核通过的音乐
    func uploadedMusic(token: String) async throws -> [UploadedMusic] {
        let response: UploadedMusicResponse = try await network.get(
            url: APIConfig.uploadedMusicURL(),
            token: token
        )
        guard response.success else {
            throw NetworkError.serverError(response.message ?? "获取上传列表失败")
        }
        return response.musicList ?? []
    }

    func upload(
        title: String,
        artist: String,
        language: String,
        album: String,
        tags: String,
        duration: Int,
        uploadUserId: Int,
        music: FilePayload,
        cover: FilePayload?,
        lyrics: FilePayload?,
        token: String
    ) async throws -> MusicUploadResponse {
        var fields: [NetworkService.MultipartField] = [
            NetworkService.MultipartField("title", value: title),
            NetworkService.MultipartField("artist", value: artist),
            NetworkService.MultipartField("language", value: language),
            NetworkService.MultipartField("album", value: album),
            NetworkService.MultipartField("tags", value: tags),
            NetworkService.MultipartField("duration", value: String(duration)),
            NetworkService.MultipartField("uploadUserId", value: String(uploadUserId)),
            NetworkService.MultipartField("musicFile", filename: music.filename, mimeType: music.mimeType, data: music.data),
        ]

        if let cover = cover {
            fields.append(NetworkService.MultipartField("coverFile", filename: cover.filename, mimeType: cover.mimeType, data: cover.data))
        }
        if let lyrics = lyrics {
            fields.append(NetworkService.MultipartField("lyricsFile", filename: lyrics.filename, mimeType: "text/plain", data: lyrics.data))
        }

        let raw = try await network.uploadForm(
            url: APIConfig.musicUploadURL(),
            fields: fields,
            token: "Bearer \(token)"
        )

        if let response = try? JSONDecoder().decode(MusicUploadResponse.self, from: raw) {
            return response
        }
        throw NetworkError.serverError(NetworkService.message(from: raw) ?? "上传失败")
    }
}
