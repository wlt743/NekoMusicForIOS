import Foundation

// MARK: - 评论模型

struct CommentUser: Codable, Hashable {
    let id: Int
    let nickname: String
}

struct MusicComment: Codable, Identifiable {
    let id: Int
    let musicId: Int
    let content: String
    let createdAt: String
    let ipRegion: String?
    let canDelete: Bool?
    let user: CommentUser
    let replyCount: Int?
    let replies: [MusicReply]?
}

struct MusicReply: Codable, Identifiable {
    let id: Int
    let content: String
    let createdAt: String
    let ipRegion: String?
    let canDelete: Bool?
    let user: CommentUser
    let replyToUser: CommentUser?
}

struct CommentPage {
    let comments: [MusicComment]
    let page: Int
    let total: Int
    let totalComments: Int
    let hasMore: Bool
}

// MARK: - 响应模型

private struct CommentListData: Codable {
    let musicId: Int
    let page: Int
    let pageSize: Int
    let total: Int
    let totalComments: Int
    let totalPages: Int
    let hasMore: Bool
    let comments: [MusicComment]
}

private struct CommentListResponse: Codable {
    let success: Bool
    let message: String?
    let data: CommentListData?
}

private struct CommentActionResponse: Codable {
    let success: Bool
    let message: String?
}

// MARK: - 服务

/// 歌曲评论：楼层 + 楼层内回复两层结构。
/// 列表无需登录；发表 / 删除需要用户令牌。
final class CommentService {
    static let shared = CommentService()

    private let network = NetworkService.shared

    private init() {}

    func fetchComments(musicId: Int, page: Int = 1, pageSize: Int = 20, token: String?) async throws -> CommentPage {
        let response: CommentListResponse = try await network.get(
            url: APIConfig.commentsURL(musicId: musicId, page: page, pageSize: pageSize),
            token: token
        )
        guard response.success, let data = response.data else {
            throw NetworkError.serverError(response.message ?? "获取评论失败")
        }
        return CommentPage(
            comments: data.comments,
            page: data.page,
            total: data.total,
            totalComments: data.totalComments,
            hasMore: data.hasMore
        )
    }

    @discardableResult
    func postComment(musicId: Int, content: String, parentId: Int? = nil, token: String) async throws -> String {
        var body: [String: Any] = ["musicId": musicId, "content": content]
        if let parentId = parentId {
            body["parentId"] = parentId
        }

        let data = try await network.rawPost(
            url: "\(APIConfig.baseURL)/api/comments",
            json: body,
            token: token
        )

        let response = try? JSONDecoder().decode(CommentActionResponse.self, from: data)
        if let response = response, !response.success {
            throw NetworkError.serverError(response.message ?? "评论失败")
        }
        return response?.message ?? "评论成功"
    }

    @discardableResult
    func deleteComment(id: Int, token: String) async throws -> String {
        let response: CommentActionResponse = try await network.delete(
            url: APIConfig.deleteCommentURL(id: id),
            token: token
        )
        if !response.success {
            throw NetworkError.serverError(response.message ?? "删除失败")
        }
        return response.message ?? "删除成功"
    }
}
