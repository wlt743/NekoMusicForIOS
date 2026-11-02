import Foundation

// MARK: - 消息模型

struct NekoNotification: Codable, Identifiable {
    let id: Int
    let type: String
    let title: String
    let body: String?
    let link: String?
    var read: Bool
    let createdAt: String
    let actor: CommentUser?

    /// 消息类型对应的图标
    var systemImage: String {
        switch type {
        case "comment_reply": return "bubble.left.and.bubble.right.fill"
        case "playlist_import": return "square.and.arrow.down.fill"
        case "upload_approved": return "checkmark.seal.fill"
        case "upload_rejected": return "xmark.seal.fill"
        default: return "bell.fill"
        }
    }
}

private struct NotificationListData: Codable {
    let items: [NekoNotification]
    let unread: Int
    let hasMore: Bool
    let latestId: Int
}

private struct NotificationListResponse: Codable {
    let success: Bool
    let message: String?
    let data: NotificationListData?
}

private struct NotificationReadData: Codable {
    let updated: Int
    let unread: Int
}

private struct NotificationReadResponse: Codable {
    let success: Bool
    let message: String?
    let data: NotificationReadData?
}

// MARK: - 服务

/// 站内消息。未读数只来自列表响应与实时通道的 ready 帧，
/// 这里用列表接口兜底（启动 / 回到前台 / 下拉刷新各拉一次）。
@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    @Published private(set) var items: [NekoNotification] = []
    @Published private(set) var unread = 0
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false

    private let latestIdKey = "notifications.latestId"
    private var streamTask: Task<Void, Never>?
    private var streamSession: URLSession?

    var latestId: Int {
        get { UserDefaults.standard.integer(forKey: latestIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: latestIdKey) }
    }

    private init() {}

    /// 拉取第一页（同时刷新未读数）。`since` 用于补拉离线期间的新消息。
    func refresh(token: String, since: Int? = nil) async {
        isLoading = true
        defer { isLoading = false }

        let url = APIConfig.notificationsURL(since: since, before: nil, limit: 30)
        do {
            let response: NotificationListResponse = try await NetworkService.shared.get(
                url: url,
                token: "Bearer \(token)"
            )
            guard response.success, let data = response.data else { return }

            if since != nil {
                let known = Set(items.map { $0.id })
                let fresh = data.items.filter { !known.contains($0.id) }
                items = (fresh + items).sorted { $0.id > $1.id }
            } else {
                items = data.items
            }

            unread = data.unread
            hasMore = data.hasMore
            if data.latestId > latestId {
                latestId = data.latestId
            }
        } catch {
            // 消息中心是辅助功能，失败不打断主流程
        }
    }

    /// 翻历史：加载比当前最旧一条更早的消息
    func loadMore(token: String) async {
        guard hasMore, let before = items.last?.id else { return }
        isLoading = true
        defer { isLoading = false }

        let url = APIConfig.notificationsURL(since: nil, before: before, limit: 30)
        do {
            let response: NotificationListResponse = try await NetworkService.shared.get(
                url: url,
                token: "Bearer \(token)"
            )
            guard response.success, let data = response.data else { return }
            let known = Set(items.map { $0.id })
            items.append(contentsOf: data.items.filter { !known.contains($0.id) })
            hasMore = data.hasMore
            unread = data.unread
        } catch {
            // 忽略
        }
    }

    /// 标记已读。`ids` 为空表示全部已读。
    func markRead(ids: [Int], token: String) async {
        struct Body: Encodable {
            let ids: [Int]
        }

        let response: NotificationReadResponse? = try? await NetworkService.shared.post(
            url: APIConfig.notificationsReadURL(),
            body: Body(ids: ids),
            token: "Bearer \(token)"
        )

        if ids.isEmpty {
            for index in items.indices {
                items[index].read = true
            }
        } else {
            let set = Set(ids)
            for index in items.indices where set.contains(items[index].id) {
                items[index].read = true
            }
        }

        if let data = response?.data {
            unread = data.unread
        }
    }

    func clear() {
        items = []
        unread = 0
        hasMore = false
    }

    // MARK: - 实时通道

    /// 建立 `/api/user/notifications/stream` 长连接。
    /// 断线后按指数退避重连；429 说明并发连接已满，按 Retry-After 等。
    /// 实时通道开关：后端 `/api/user/notifications/stream` 目前经 CDN 后不返回任何数据
    /// （curl 连接建立但无响应头），开启只会挂住连接。列表接口已能兜底，先默认关闭。
    private let realtimeStreamEnabled = false

    func startStream(token: String) {
        guard realtimeStreamEnabled else { return }
        NSLog("[NekoStream] startStream called")
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            await self?.runStream(token: token)
        }
    }

    func stopStream() {
        streamTask?.cancel()
        streamTask = nil
        streamSession?.invalidateAndCancel()
        streamSession = nil
    }

    private func runStream(token: String) async {
        NSLog("[NekoStream] runStream begin")
        var backoff: UInt64 = 3

        while !Task.isCancelled {
            do {
                try await connectOnce(token: token)
                backoff = 3
            } catch is CancellationError {
                return
            } catch let error as StreamError {
                if case .tooManyConnections = error {
                    backoff = max(backoff, 30)
                }
                NSLog("[NekoStream] %@", "\(error)")
            } catch {
                NSLog("[NekoStream] %@", "\(error)")
            }

            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 60)
        }
    }

    private enum StreamError: Error, CustomStringConvertible {
        case unauthorized
        case tooManyConnections
        case badStatus(Int)

        var description: String {
            switch self {
            case .unauthorized: return "unauthorized"
            case .tooManyConnections: return "too many connections"
            case .badStatus(let code): return "status \(code)"
            }
        }
    }

    private func connectOnce(token: String) async throws {
        var components = URLComponents(string: "\(APIConfig.baseURL)/api/user/notifications/stream")
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else { throw StreamError.badStatus(-1) }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        config.httpAdditionalHeaders = APIConfig.clientHeaders
        let session = URLSession(configuration: config)
        streamSession = session
        defer {
            session.invalidateAndCancel()
            if streamSession === session { streamSession = nil }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 600
        for (key, value) in APIConfig.clientHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw StreamError.badStatus(-1) }

        switch http.statusCode {
        case 200: break
        case 401: throw StreamError.unauthorized
        case 429: throw StreamError.tooManyConnections
        default: throw StreamError.badStatus(http.statusCode)
        }
        NSLog("[NekoStream] connected")

        var eventName = ""
        var dataLines: [String] = []

        for try await line in bytes.lines {
            if Task.isCancelled { return }
            if line.isEmpty {
                if !dataLines.isEmpty {
                    handleStreamEvent(name: eventName, payload: dataLines.joined(separator: "\n"), token: token)
                }
                eventName = ""
                dataLines = []
                continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("retry:") || line.hasPrefix("id:") { continue }
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    private func handleStreamEvent(name: String, payload: String, token: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return
        }

        switch name {
        case "ready":
            if let unreadCount = json["unread"] as? Int {
                unread = unreadCount
            }
            NSLog("[NekoStream] ready unread=%d", unread)
            let latest = json["latestId"] as? Int ?? 0
            if latest > latestId {
                Task { await refresh(token: token, since: latestId) }
            }

        case "message":
            guard let item = try? JSONDecoder().decode(NekoNotification.self, from: Data(payload.utf8)) else {
                return
            }
            if !items.contains(where: { $0.id == item.id }) {
                items.insert(item, at: 0)
            }
            if !item.read {
                unread += 1
            }
            if item.id > latestId {
                latestId = item.id
            }
            NSLog("[NekoStream] message id=%d unread=%d", item.id, unread)

        default:
            break
        }
    }
}
