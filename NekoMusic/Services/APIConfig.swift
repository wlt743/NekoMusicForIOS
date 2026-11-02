import Foundation

enum APIConfig {
    /// 接口地址由用户首次启动时选择或填写（见 ServerConfig）。
    /// 应用本身不内置、也不默认连接任何服务；未配置时为空字符串。
    /// 网络代码在多个线程读取，这里用非隔离静态变量，由 ServerConfig 在配置变更时写入。
    nonisolated(unsafe) static var baseURL: String = ""

    /// 客户端标识，后端用于区分官方客户端 / 第三方客户端
    static let clientVersion = "26.10.2"
    static let clientHeader = "ios+\(clientVersion)"
    /// 后端要求 UA 里必须出现平台名（ios），同时又要"像浏览器"，
    /// 所以用 iOS Safari 的形态 + 显式 iOS 版本号。桌面 UA 会被判平台不符。
    static let userAgent = "NekoMusic/\(clientVersion) (iPhone; iOS 26.0; Scale/3.0)"
    static let browserUserAgent = "Mozilla/5.0 (iPhone; iOS 26.0; Scale/3.0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    // MARK: - 客户端身份（Client ID）
    //
    // 后端 2026-10 起要求除公开接口外的所有 /api/*、/loser/* 动态请求都证明
    // 「客户端应用 + 安装实例」的身份：Client ID、实例 UUID、实例短期令牌、每请求签名。
    // Client ID 由管理员人工分配，绑定平台，不能跨平台使用。
    static let clientID = "nkc_pub_3dcfca6e3c084b798872"
    static let clientPlatform = "ios"

    // MARK: - 客户端请求头
    //
    // 后端启用了「防爬与客户端识别」：请求头不完整会被判成爬虫，
    // 表现为 403 或降级成 SEO 页面，所以这里必须带齐。
    static var clientHeaders: [String: String] {
        [
            // 换成题接口要求「像浏览器」的指纹：Chromium 系的 UA + client hints。
            // 只写 NekoMusic UA 会被判成「环境异常」（403）。
            "User-Agent": browserUserAgent,
            "X-Neko-Client": clientHeader,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            // 不能用 URLSession 默认的 "gzip, deflate, br"，带 br 会被风控拒绝
            "Accept-Encoding": "identity",
            "X-Requested-With": "XMLHttpRequest",
            "sec-ch-ua-mobile": "?1",
            "sec-ch-ua-platform": "\"iOS\"",
            "Referer": "\(baseURL)/",
            "Origin": baseURL,
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin",
        ]
    }

    /// 不需要 nonce 的接口（后端白名单）
    static func requiresNonce(path: String) -> Bool {
        let p = path.hasPrefix("/") ? path : "/" + path
        let whitelistPrefixes = [
            "/api/replay/",
            "/api/music/cover/",
            "/api/user/avatar/",
            "/media/",
            "/assets/",
            "/loser/",
        ]
        for prefix in whitelistPrefixes where p.hasPrefix(prefix) {
            return false
        }
        let whitelistPaths = [
            "/api/music/latest",
            "/api/music/ranking",
        ]
        return !whitelistPaths.contains { p.hasPrefix($0) }
    }

    /// 不需要「客户端身份」（实例令牌 + 请求签名）的接口，见文档第 7 节
    static func requiresClientIdentity(path: String) -> Bool {
        let p = path.hasPrefix("/") ? path : "/" + path

        // 自举接口：拿挑战 / 注册 / 续签本身不能要求身份
        let bootstrapPrefixes = [
            "/api/client/",
            "/api/replay/",
            "/api/music/cover/",
            "/api/user/avatar/",
            "/media/",
            "/assets/",
        ]
        for prefix in bootstrapPrefixes where p.hasPrefix(prefix) {
            return false
        }

        let exemptPaths = [
            "/api/music/latest",
            "/api/music/ranking",
            "/api/user/qrlogin/status",
            "/api/user/notifications/stream",
            "/api/payment/zpay/notify",
        ]
        if exemptPaths.contains(where: { p.hasPrefix($0) }) { return false }

        // 歌单导入进度 SSE 不签名，其它 /loser/* 仍要
        if p.hasPrefix("/loser/") && p.hasSuffix("/pull") { return false }

        return true
    }

    // MARK: - 客户端身份（自举）
    static func clientChallengeURL() -> String { "\(baseURL)/api/client/challenge" }

    // MARK: - 防重放 nonce
    static func replayChallengeURL() -> String { "\(baseURL)/api/replay/challenge" }
    static func replayNonceURL() -> String { "\(baseURL)/api/replay/nonce" }

    // MARK: - Music APIs
    static func musicSearchURL() -> String { "\(baseURL)/api/music/search" }
    /// 注意：新版本的 ranking / latest 已移除 limit 参数，固定返回 200 / 300 首
    static func musicRankingURL() -> String { "\(baseURL)/api/music/ranking" }
    static func musicLatestURL() -> String { "\(baseURL)/api/music/latest" }
    static func musicFileURL(id: Int, quality: String = "hq") -> String {
        "\(baseURL)/api/music/file/\(id)?quality=\(quality)"
    }
    static func musicCoverURL(id: Int) -> String { "\(baseURL)/api/music/cover/\(id)" }
    static func musicInfoURL(id: Int) -> String { "\(baseURL)/api/music/info/\(id)" }

    // MARK: - 分享视频渲染
    static func videoRenderCreateURL() -> String { "\(baseURL)/api/video/render/create" }
    static func videoRenderStatusURL(jobId: String) -> String { "\(baseURL)/api/video/render/\(jobId)" }
    static func videoRenderDownloadURL(jobId: String) -> String { "\(baseURL)/api/video/render/\(jobId)/download" }

    /// 听歌识曲
    static func recognizeURL() -> String { "\(baseURL)/api/music/recognize" }

    // MARK: - Captcha APIs
    static func sliderCaptchaURL() -> String { "\(baseURL)/api/captcha/slider" }
    static func sliderVerifyURL() -> String { "\(baseURL)/api/captcha/slider/verify" }

    // MARK: - User APIs
    static func loginURL() -> String { "\(baseURL)/api/user/login" }
    static func registerURL() -> String { "\(baseURL)/api/user/register" }
    static func sendVerificationURL() -> String { "\(baseURL)/api/user/send-verification" }
    static func sendResetCodeURL() -> String { "\(baseURL)/api/user/send-reset-code" }
    static func resetPasswordURL() -> String { "\(baseURL)/api/user/reset-password" }
    static func changePasswordURL() -> String { "\(baseURL)/api/user/password/change" }
    static func changeNicknameURL() -> String { "\(baseURL)/api/user/nickname/change" }
    static func notificationsURL(since: Int?, before: Int?, limit: Int) -> String {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let since = since { items.append(URLQueryItem(name: "since", value: String(since))) }
        if let before = before { items.append(URLQueryItem(name: "before", value: String(before))) }
        var components = URLComponents(string: "\(baseURL)/api/user/notifications")
        components?.queryItems = items
        return components?.url?.absoluteString ?? "\(baseURL)/api/user/notifications"
    }
    static func notificationsReadURL() -> String { "\(baseURL)/api/user/notifications/read" }
    static func userAvatarURL(id: Int) -> String { "\(baseURL)/api/user/avatar/\(id)" }
    static func avatarUploadURL() -> String { "\(baseURL)/api/user/avatar/upload" }
    static func musicUploadURL() -> String { "\(baseURL)/api/user/upload" }

    // MARK: - VIP
    static func vipPricingURL() -> String { "\(baseURL)/api/vip/pricing" }
    static func vipPayCreateURL() -> String { "\(baseURL)/api/vip/pay/create" }
    static func dailyRecommendationsURL() -> String { "\(baseURL)/api/user/recommendations/daily" }

    // MARK: - Favorite APIs
    static func favoritesURL() -> String { "\(baseURL)/api/user/favorites" }
    static func removeFavoriteURL(musicId: Int) -> String { "\(baseURL)/api/user/favorites/\(musicId)" }

    // MARK: - Playlist APIs
    static func playlistSearchURL() -> String { "\(baseURL)/api/playlists/search" }
    static func myPlaylistsURL() -> String { "\(baseURL)/api/user/playlists" }
    static func playlistCreateURL() -> String { "\(baseURL)/api/user/playlist/create" }
    static func playlistDeleteURL() -> String { "\(baseURL)/api/user/playlist/delete" }
    static func playlistMusicURL(id: Int) -> String { "\(baseURL)/api/user/playlist/music/\(id)" }
    static func playlistDetailURL(id: Int) -> String { "\(baseURL)/api/playlist/\(id)" }
    static func playlistAddMusicURL() -> String { "\(baseURL)/api/user/playlist/music/add" }
    static func playlistRemoveMusicURL() -> String { "\(baseURL)/api/user/playlist/music/remove" }

    // MARK: - 收藏歌单
    static func favoritePlaylistsURL() -> String { "\(baseURL)/api/user/favorite-playlists" }
    static func favoritePlaylistURL(id: Int) -> String { "\(baseURL)/api/user/favorite-playlists/\(id)" }

    // MARK: - 歌单编辑
    static func playlistUpdateURL() -> String { "\(baseURL)/api/user/playlist/update" }

    // MARK: - 我上传的音乐
    static func uploadedMusicURL() -> String { "\(baseURL)/api/user/uploaded-music" }

    // MARK: - 扫码登录
    static func qrScanURL() -> String { "\(baseURL)/api/user/qrlogin/scan" }
    static func qrConfirmURL() -> String { "\(baseURL)/api/user/qrlogin/confirm" }

    // MARK: - Comments API
    static func commentsURL(musicId: Int, page: Int = 1, pageSize: Int = 20) -> String {
        "\(baseURL)/api/comments?musicId=\(musicId)&page=\(page)&pageSize=\(pageSize)"
    }
    static func deleteCommentURL(id: Int) -> String {
        "\(baseURL)/api/comments?id=\(id)"
    }

    // MARK: - 外部歌单导入（/loser/*，白名单内，无需 nonce）
    static func pullURL(path: String) -> String { "\(baseURL)/loser/\(path)" }

    // MARK: - Helpers
    static func buildFullURL(path: String) -> String {
        if path.hasPrefix("http") {
            return path
        }
        if path.hasPrefix("/") {
            return "\(baseURL)\(path)"
        }
        return path
    }

    static func buildMusicCoverURL(musicId: Int, coverFilePath: String?) -> String {
        if let coverPath = coverFilePath, !coverPath.isEmpty {
            if coverPath.hasPrefix("http") {
                return coverPath
            }
            if coverPath.hasPrefix("/api/music/cover/") || coverPath.contains("/media/") {
                return "\(baseURL)\(coverPath)"
            }
        }
        return musicCoverURL(id: musicId)
    }
}
