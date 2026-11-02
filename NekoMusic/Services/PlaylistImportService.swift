import Foundation

// MARK: - 导入平台

/// 后端 `/loser/{source}/pull` 支持的四家音源。
enum ImportPlatform: String, CaseIterable, Identifiable {
    case netease
    case qq
    case kugou
    case qishui

    var id: String { rawValue }

    var title: String {
        switch self {
        case .netease: return "网易云"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗"
        case .qishui: return "汽水"
        }
    }

    var icon: String {
        switch self {
        case .netease: return "cloud"
        case .qq: return "music.quarternote.3"
        case .kugou: return "waveform"
        case .qishui: return "drop"
        }
    }

    var placeholder: String {
        switch self {
        case .netease: return "网易云歌单链接或 ID"
        case .qq: return "QQ 音乐歌单链接或 ID"
        case .kugou: return "酷狗歌单链接、gcid 或 ID"
        case .qishui: return "汽水歌单链接或 ID"
        }
    }

    var hint: String {
        switch self {
        case .netease: return "支持 https://music.163.com/playlist?id=… 或纯数字 ID"
        case .qq: return "支持 https://y.qq.com/n/ryqq/playlist/… 或纯数字 ID"
        case .kugou: return "支持网页/移动端分享链接、gcid 短链或数字 ID"
        case .qishui: return "支持汽水/抖音分享链接、短链或纯数字 ID"
        }
    }

    /// `/loser` 下的路径
    var pullPath: String { "\(rawValue)/pull" }

    /// 歌单 ID 的查询参数名
    var idParam: String {
        switch self {
        case .netease: return "playlistId"
        case .qq: return "disstid"
        case .kugou: return "listid"
        case .qishui: return "playlist_id"
        }
    }

    /// 酷狗 / 汽水 的链接由后端解析，客户端原样传即可。
    var acceptsRawLink: Bool {
        self == .kugou || self == .qishui
    }
}

// MARK: - SSE 事件模型

enum ImportTrackStatus: String {
    case downloading
    case matching
    case imported
    case existed
    case failed

    var label: String {
        switch self {
        case .downloading: return "下载中"
        case .matching: return "匹配中"
        case .imported: return "已入库"
        case .existed: return "曲库已有"
        case .failed: return "失败"
        }
    }

    var systemImage: String {
        switch self {
        case .downloading: return "arrow.down.circle"
        case .matching: return "magnifyingglass"
        case .imported: return "checkmark.circle.fill"
        case .existed: return "square.stack.3d.up.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isFailure: Bool { self == .failed }
}

struct ImportTrack: Identifiable {
    let index: Int
    var title: String
    var artist: String
    var status: ImportTrackStatus
    var message: String?

    var id: Int { index }
}

struct ImportStartInfo {
    let source: String
    let total: Int
    let targetPlaylistId: Int?
    let targetPlaylistCreated: Bool
}

struct ImportProgressInfo {
    let index: Int
    let total: Int
    let percent: Int
}

struct ImportSummary {
    let total: Int
    let imported: Int
    let existed: Int
    let failed: Int

    var succeeded: Int { imported + existed }
}

enum ImportEvent {
    case started(ImportStartInfo)
    case track(ImportTrack)
    case progress(ImportProgressInfo)
    case done(ImportSummary)
    case failure(String)
}

// MARK: - 导入服务

/// 外部歌单导入。
///
/// 后端 `/loser/{source}/pull` 会自己完成「站外匹配 + 下载入库 + 加入站内歌单」，
/// 并通过 SSE 实时推送进度，客户端只负责发起请求和展示。
final class PlaylistImportService {
    static let shared = PlaylistImportService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 900
        config.httpAdditionalHeaders = APIConfig.clientHeaders
        session = URLSession(configuration: config)
    }

    // MARK: 输入解析

    /// 把用户粘贴的链接 / ID 规范成后端需要的参数值。
    func resolveInput(_ raw: String, platform: ImportPlatform) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 酷狗 / 汽水的链接格式非常多，交给后端解析
        if platform.acceptsRawLink { return text }

        if text.allSatisfy({ $0.isNumber }) { return text }

        let patterns: [String]
        switch platform {
        case .netease:
            patterns = ["[?&]id=(\\d+)", "playlist/(\\d+)", "playlist\\?id=(\\d+)"]
        case .qq:
            patterns = ["disstid=(\\d+)", "playlist/(\\d+)", "[?&]id=(\\d+)"]
        case .kugou, .qishui:
            patterns = ["(\\d{5,})"]
        }

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    // MARK: 发起导入

    /// 发起一次导入并流式返回进度事件。
    /// - Parameters:
    ///   - targetPlaylistId: 导入到已有歌单（与 targetPlaylistName 二选一）
    ///   - targetPlaylistName: 新建歌单并导入（与 targetPlaylistId 二选一）
    func streamImport(
        platform: ImportPlatform,
        input: String,
        targetPlaylistId: Int?,
        targetPlaylistName: String?,
        token: String
    ) -> AsyncThrowingStream<ImportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(
                        platform: platform,
                        input: input,
                        targetPlaylistId: targetPlaylistId,
                        targetPlaylistName: targetPlaylistName,
                        token: token,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 内部实现

    private func run(
        platform: ImportPlatform,
        input: String,
        targetPlaylistId: Int?,
        targetPlaylistName: String?,
        token: String,
        continuation: AsyncThrowingStream<ImportEvent, Error>.Continuation
    ) async throws {
        guard var components = URLComponents(string: APIConfig.pullURL(path: platform.pullPath)) else {
            throw NetworkError.invalidURL
        }

        var query = [URLQueryItem(name: platform.idParam, value: input)]
        if let targetPlaylistId = targetPlaylistId {
            query.append(URLQueryItem(name: "targetPlaylistId", value: String(targetPlaylistId)))
        } else if let name = targetPlaylistName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            query.append(URLQueryItem(name: "targetPlaylistName", value: name))
        }
        components.queryItems = query

        guard let url = components.url else { throw NetworkError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 600
        for (key, value) in APIConfig.clientHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // SSE 必须覆盖默认的 JSON Accept，否则后端可能不会走流式分支
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(token, forHTTPHeaderField: "Authorization")

        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else { throw NetworkError.noData }

        if http.statusCode == 401 {
            throw NetworkError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 8192 { break }
            }
            let message = NetworkService.message(from: data) ?? "导入失败（\(http.statusCode)）"
            throw NetworkError.serverError(message)
        }

        var eventName = ""
        var dataLines: [String] = []

        for try await line in bytes.lines {
            if line.isEmpty {
                if !dataLines.isEmpty {
                    emit(event: eventName, payload: dataLines.joined(separator: "\n"), to: continuation)
                }
                eventName = ""
                dataLines = []
                continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }

        // 流结束时可能还剩最后一个事件（部分实现不发结尾空行）
        if !dataLines.isEmpty {
            emit(event: eventName, payload: dataLines.joined(separator: "\n"), to: continuation)
        }
    }

    private func emit(
        event: String,
        payload: String,
        to continuation: AsyncThrowingStream<ImportEvent, Error>.Continuation
    ) {
        guard let json = Self.jsonObject(payload) else { return }

        switch event {
        case "start":
            continuation.yield(.started(ImportStartInfo(
                source: Self.string(json["source"]) ?? "unknown",
                total: Self.int(json["total"]) ?? 0,
                targetPlaylistId: Self.int(json["targetPlaylistId"]),
                targetPlaylistCreated: json["targetPlaylistCreated"] as? Bool ?? false
            )))

        case "track":
            guard let track = Self.makeTrack(from: json) else { return }
            continuation.yield(.track(track))

        case "progress":
            continuation.yield(.progress(ImportProgressInfo(
                index: Self.int(json["index"]) ?? 0,
                total: Self.int(json["total"]) ?? 0,
                percent: Self.int(json["percent"]) ?? -1
            )))

        case "done":
            continuation.yield(.done(ImportSummary(
                total: Self.int(json["total"]) ?? 0,
                imported: Self.int(json["imported"]) ?? 0,
                existed: Self.int(json["existed"]) ?? 0,
                failed: Self.int(json["failed"]) ?? 0
            )))

        case "error":
            continuation.yield(.failure(Self.string(json["message"]) ?? "导入失败"))

        default:
            break
        }
    }

    private static func makeTrack(from json: [String: Any]) -> ImportTrack? {
        let index = int(json["index"]) ?? 0
        let title = string(json["title"]) ?? "未知曲目"
        let artist = string(json["artist"]) ?? ""
        let status = ImportTrackStatus(rawValue: string(json["status"]) ?? "") ?? .matching
        return ImportTrack(
            index: index,
            title: title,
            artist: artist,
            status: status,
            message: string(json["message"])
        )
    }

    // MARK: 类型转换

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
