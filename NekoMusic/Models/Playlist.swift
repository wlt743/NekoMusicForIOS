import Foundation

struct Playlist: Codable, Identifiable {
    let id: Int
    let name: String
    let musicCount: Int
    let userId: Int?
    let createdAt: String
    let coverPath: String?
    let description: String?
    let username: String?
    let creatorAvatar: String?
}

struct PlaylistInfo: Codable, Identifiable {
    let id: Int
    let name: String
    let description: String?
    let coverPath: String?
    let musicCount: Int
    let createdAt: String
    let updatedAt: String
    let userId: Int?
    let username: String?
    let creatorAvatar: String?
    let firstMusicCover: String?
}

struct PlaylistMusic: Codable, Identifiable {
    let id: Int
    let title: String
    let artist: String
    let album: String
    let duration: Int
    let coverPath: String?
    /// 文档里的音乐列表不保证返回直链，缺省时按 musicId 走 `/api/music/file/{id}`
    let filePath: String?
    let fileFormat: String?
    let language: String?
    let position: Int?
    let addedAt: String?
    let maxQuality: String?
}

struct PlaylistListResponse: Codable {
    let success: Bool
    let message: String?
    let playlists: [PlaylistInfo]?
    let results: [PlaylistInfo]?
    let isVip: Bool?
    let vipExpiresAt: String?
}

struct PlaylistResponse: Codable {
    let success: Bool
    let message: String?
    let playlist: PlaylistInfo?
}

struct PlaylistMusicListResponse: Codable {
    let success: Bool
    let message: String
    let playlistId: Int
    let total: Int
    let musicList: [PlaylistMusic]?
}

struct FavoriteMusic: Codable, Identifiable {
    let id: Int
    let title: String
    let artist: String
    let album: String
    let duration: Int
    let filename: String
    let cover: String?
}

struct FavoriteListResponse: Codable {
    let success: Bool
    let favorites: [FavoriteMusic]
}

struct FavoriteResponse: Codable {
    let success: Bool
    let message: String
}


// MARK: - 收藏歌单

struct PlaylistCreator: Codable {
    let id: Int
    let nickname: String
}

struct FavoritePlaylist: Codable, Identifiable {
    let id: Int
    let name: String
    let description: String?
    let musicCount: Int
    let createdAt: Double?
    let updatedAt: Double?
    let favoriteTime: Double?
    let creator: PlaylistCreator?
}

struct FavoritePlaylistListResponse: Codable {
    let success: Bool
    let message: String?
    let playlists: [FavoritePlaylist]?
}

struct FavoritePlaylistMusic: Codable, Identifiable {
    let id: Int
    let title: String
    let artist: String
    let album: String?
    let duration: Int?
    let maxQuality: String?
    let filename: String?
    let position: Int?
}

struct FavoritePlaylistMusicResponse: Codable {
    let success: Bool
    let message: String?
    let music: [FavoritePlaylistMusic]?
}

// MARK: - 歌单编辑

struct PlaylistUpdateResponse: Codable {
    let success: Bool
    let message: String?
    let playlist: PlaylistInfo?
}

// MARK: - 我上传的音乐

struct UploadedMusic: Codable, Identifiable {
    let id: Int
    let title: String
    let artist: String
    let album: String?
    let duration: Int?
    let language: String?
    let tags: String?
    let fileFormat: String?
    let maxQuality: String?
    let createdAt: String?
}

struct UploadedMusicResponse: Codable {
    let success: Bool
    let message: String?
    let total: Int?
    let musicList: [UploadedMusic]?
}
