import Foundation
import SwiftUI

/// 接口服务器配置。
///
/// 应用不内置曲库、不默认连接任何服务；首次启动由用户明确选择来源类型并填写地址，
/// 内容来源与合法性由用户自行负责。
@MainActor
final class ServerConfig: ObservableObject {

    /// 来源类型
    enum SourceKind: String, CaseIterable, Identifiable {
        case neko          // NekoMusic 协议（社区常用地址）
        case nekoCustom    // NekoMusic 协议（自填地址）
        case subsonic      // Subsonic / Navidrome 兼容
        case jellyfin      // Jellyfin / Emby
        case generic       // 通用接口（仅保存地址）

        var id: String { rawValue }

        var title: String {
            switch self {
            case .neko: return "使用 NekoMusic 资源"
            case .nekoCustom: return "自配置 NekoMusic 地址"
            case .subsonic: return "Subsonic 兼容服务器"
            case .jellyfin: return "Jellyfin / Emby"
            case .generic: return "通用接口"
            }
        }

        var subtitle: String {
            switch self {
            case .neko: return "社区常用地址，由第三方提供与维护"
            case .nekoCustom: return "你自己的 NekoMusic 协议服务器"
            case .subsonic: return "Navidrome、Airsonic 等，需要账号密码"
            case .jellyfin: return "需要 API Key 或账号密码"
            case .generic: return "任意 HTTP 接口，仅保存地址与令牌"
            }
        }

        var icon: String {
            switch self {
            case .neko: return "music.note.house"
            case .nekoCustom: return "server.rack"
            case .subsonic: return "waveform.path.ecg"
            case .jellyfin: return "play.tv"
            case .generic: return "network"
            }
        }

        /// 当前是否已支持播放（其余类型先支持保存与连通性校验）
        var playbackSupported: Bool {
            self == .neko || self == .nekoCustom || self == .subsonic
        }
    }

    struct Credentials: Codable, Equatable {
        var username: String = ""
        var password: String = ""
        var token: String = ""
    }

    static let shared = ServerConfig()

    /// 社区常用地址（仅供用户选择，不是默认值）
    static let presetURL = "https://music.nekocore.cn"

    private enum Keys {
        static let kind = "neko.source.kind"
        static let url = "neko.source.url"
        static let credentials = "neko.source.credentials"
        static let termsAccepted = "neko.terms.accepted"
    }

    @Published private(set) var kind: SourceKind?
    @Published private(set) var baseURL: String
    @Published private(set) var credentials: Credentials
    @Published private(set) var hasAcceptedTerms: Bool

    private let defaults = UserDefaults.standard

    private init() {
        let savedKind = SourceKind(rawValue: defaults.string(forKey: Keys.kind) ?? "")
        kind = savedKind
        baseURL = defaults.string(forKey: Keys.url) ?? ""
        if let data = defaults.data(forKey: Keys.credentials),
           let saved = try? JSONDecoder().decode(Credentials.self, from: data) {
            credentials = saved
        } else {
            credentials = Credentials()
        }
        hasAcceptedTerms = defaults.bool(forKey: Keys.termsAccepted)
        APIConfig.baseURL = kind?.playbackSupported == true ? baseURL : ""
        ServerConfigSnapshot.baseURL = baseURL
        ServerConfigSnapshot.username = credentials.username
        ServerConfigSnapshot.password = credentials.password
        ServerConfigSnapshot.isSubsonic = (kind == .subsonic)
    }

    /// 首次启动流程是否走完（同意了协议且选好了来源）
    var isReady: Bool {
        hasAcceptedTerms && kind != nil && !baseURL.isEmpty && URL(string: baseURL) != nil
    }

    /// 当前来源是否支持播放
    var isPlaybackSupported: Bool {
        kind?.playbackSupported ?? false
    }

    func acceptTerms() {
        hasAcceptedTerms = true
        defaults.set(true, forKey: Keys.termsAccepted)
    }

    // MARK: - 保存

    private func apply(kind: SourceKind, url: String, credentials: Credentials) {
        self.kind = kind
        baseURL = url
        self.credentials = credentials
        defaults.set(kind.rawValue, forKey: Keys.kind)
        defaults.set(url, forKey: Keys.url)
        if let data = try? JSONEncoder().encode(credentials) {
            defaults.set(data, forKey: Keys.credentials)
        }
        // NekoMusic 协议才把地址喂给网络层；Subsonic 走独立客户端
        APIConfig.baseURL = kind.playbackSupported ? url : ""
        ServerConfigSnapshot.baseURL = url
        ServerConfigSnapshot.username = credentials.username
        ServerConfigSnapshot.password = credentials.password
        ServerConfigSnapshot.isSubsonic = (kind == .subsonic)
    }

    // MARK: - 连通性校验

    /// 校验并保存。成功返回 nil，失败返回原因。
    func verifyAndSave(kind: SourceKind, rawURL: String, credentials: Credentials) async -> String? {
        var url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parsed.host?.isEmpty == false else {
            return "地址无效，请填入以 http:// 或 https:// 开头的完整地址"
        }

        if let error = await Self.checkReachability(kind: kind, base: url, credentials: credentials) {
            return error
        }
        apply(kind: kind, url: url, credentials: credentials)
        await ClientIdentityService.shared.resetForNewServer()
        // 重建界面，避免首页还留着上一个服务器的列表
        AppReloader.shared.reload()
        return nil
    }

    private static func checkReachability(kind: SourceKind, base: String,
                                          credentials: Credentials) async -> String? {
        switch kind {
        case .neko:
            return nil   // 社区地址无需校验
        case .nekoCustom:
            return await probe("\(base)/api/music/latest?limit=1", expectJSON: true)
        case .subsonic:
            guard !credentials.username.isEmpty else { return "请填写用户名" }
            var comps = URLComponents(string: "\(base)/rest/ping.view")
            comps?.queryItems = [
                URLQueryItem(name: "u", value: credentials.username),
                URLQueryItem(name: "p", value: credentials.password),
                URLQueryItem(name: "v", value: "1.16.1"),
                URLQueryItem(name: "c", value: "NekoMusic"),
                URLQueryItem(name: "f", value: "json"),
            ]
            guard let url = comps?.url else { return "地址无效" }
            return await probe(url.absoluteString, expectJSON: true, subsonicPing: true)
        case .jellyfin:
            return await probe("\(base)/System/Info/Public", expectJSON: true)
        case .generic:
            return await probe(base, expectJSON: false)
        }
    }

    private static func probe(_ urlString: String, expectJSON: Bool,
                              subsonicPing: Bool = false) async -> String? {
        guard let url = URL(string: urlString) else { return "地址无效" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "服务器无响应" }
            guard (200...399).contains(http.statusCode) else {
                return "服务器返回 \(http.statusCode)，请检查地址与凭据"
            }
            if subsonicPing {
                guard let text = String(data: data, encoding: .utf8),
                      text.contains("\"ok\"") else {
                    return "认证失败：请检查用户名与密码"
                }
            } else if expectJSON {
                _ = try? JSONSerialization.jsonObject(with: data)
            }
            return nil
        } catch {
            return "无法连接：\(error.localizedDescription)"
        }
    }
}
