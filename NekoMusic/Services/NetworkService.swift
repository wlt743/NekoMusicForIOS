import Foundation

enum NetworkError: Error, LocalizedError {
    case invalidURL
    case noData
    case decodingError(Error)
    case serverError(String)
    case unauthorized
    case networkError(Error)
    case serverBusy
    /// 429：操作太频繁（评论 5 秒间隔、连接数上限等）
    case tooManyRequests

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的URL"
        case .noData: return "没有数据"
        case .decodingError(let error): return "数据解析错误: \(error.localizedDescription)"
        case .serverError(let message): return message
        case .unauthorized: return "未授权，请重新登录"
        case .networkError(let error):
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut || nsError.code == NSURLErrorNetworkConnectionLost {
                return "服务器繁忙，请稍后再试"
            }
            return "网络错误: \(error.localizedDescription)"
        case .serverBusy: return "服务器繁忙，请稍后再试"
        case .tooManyRequests: return "操作太频繁，请稍后再试"
        }
    }
}

/// 统一网络层。
///
/// 后端要求：
/// 1. 所有请求都带客户端识别头（否则会被判成爬虫，返回 403 / SEO 页面）；
/// 2. 除白名单外的接口都要带一次性 `X-Neko-Nonce`；
/// 3. nonce 失效 / 重放返回 409，客户端应换一个 nonce 重试一次。
class NetworkService {
    static let shared = NetworkService()

    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = APIConfig.clientHeaders
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
    }

    // MARK: - Generic Request Methods

    func get<T: Decodable>(url: String, token: String? = nil) async throws -> T {
        let data = try await send(url: url, method: "GET", body: nil, token: token)
        return try decode(T.self, from: data)
    }

    func post<T: Decodable>(url: String, body: Encodable, token: String? = nil) async throws -> T {
        let encoder = JSONEncoder()
        let data = try encoder.encode(body)
        let responseData = try await send(url: url, method: "POST", body: data, token: token)
        return try decode(T.self, from: responseData)
    }

    func delete<T: Decodable>(url: String, token: String? = nil) async throws -> T {
        let data = try await send(url: url, method: "DELETE", body: nil, token: token)
        return try decode(T.self, from: data)
    }

    func getRawString(url: String, token: String? = nil) async throws -> String {
        let data = try await send(url: url, method: "GET", body: nil, token: token)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 供自定义图片加载器使用：带客户端头拉取二进制资源
    func fetchData(url: String) async throws -> Data {
        try await send(url: url, method: "GET", body: nil, token: nil)
    }

    /// 需要手工解析 JSON 的场景（音乐接口的字段比较松散）
    func rawGet(url: String, token: String? = nil) async throws -> Data {
        try await send(url: url, method: "GET", body: nil, token: token)
    }

    func rawPost(url: String, json: [String: Any], token: String? = nil) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await send(url: url, method: "POST", body: body, token: token)
    }

    struct MultipartField {
        let name: String
        var value: String?
        var filename: String?
        var mimeType: String?
        var data: Data?

        init(_ name: String, value: String? = nil, filename: String? = nil, mimeType: String? = nil, data: Data? = nil) {
            self.name = name
            self.value = value
            self.filename = filename
            self.mimeType = mimeType
            self.data = data
        }
    }

    /// 单文件上传（头像）
    func uploadMultipart(
        url: String,
        fieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        token: String? = nil
    ) async throws -> Data {
        try await uploadForm(
            url: url,
            fields: [MultipartField(fieldName, filename: filename, mimeType: mimeType, data: fileData)],
            token: token
        )
    }

    /// 通用 multipart/form-data 上传（头像、用户上传音乐）
    func uploadForm(url: String, fields: [MultipartField], token: String? = nil) async throws -> Data {
        guard let requestURL = URL(string: url) else { throw NetworkError.invalidURL }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func append(_ text: String) {
            body.append(Data(text.utf8))
        }

        for field in fields {
            append("--\(boundary)\r\n")
            if let filename = field.filename {
                append("Content-Disposition: form-data; name=\"\(field.name)\"; filename=\"\(filename)\"\r\n")
                append("Content-Type: \(field.mimeType ?? "application/octet-stream")\r\n\r\n")
                body.append(field.data ?? Data())
                append("\r\n")
            } else {
                append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
                append(field.value ?? "")
                append("\r\n")
            }
        }
        append("--\(boundary)--\r\n")

        let path = requestURL.path
        let rawQuery = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        let needsNonce = APIConfig.requiresNonce(path: path)
        let needsIdentity = APIConfig.requiresClientIdentity(path: path)
        var nonceRefreshed = false
        var identityRefreshed = false

        for _ in 0..<3 {
            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            for (key, value) in APIConfig.clientHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            if let token = token {
                request.setValue(token, forHTTPHeaderField: "Authorization")
            }
            request.httpBody = body

            var nonce = ""
            if needsNonce {
                nonce = try await NonceService.shared.nextNonce(forWrite: true)
                request.setValue(nonce, forHTTPHeaderField: "X-Neko-Nonce")
            }

            if needsIdentity {
                do {
                    let headers = try await ClientIdentityService.shared.headers(
                        method: "POST",
                        path: path,
                        rawQuery: rawQuery,
                        bodyHash: ClientIdentityService.multipartBodyHash,
                        nonce: nonce
                    )
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                } catch {
                    throw NetworkError.serverError(error.localizedDescription)
                }
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NetworkError.noData }

            if http.statusCode == 409, !nonceRefreshed {
                nonceRefreshed = true
                await NonceService.shared.invalidatePool()
                continue
            }
            if http.statusCode == 401,
               http.value(forHTTPHeaderField: "X-Neko-Client-Status")?.lowercased() == "invalid",
               !identityRefreshed {
                identityRefreshed = true
                await ClientIdentityService.shared.invalidate()
                continue
            }
            if http.statusCode == 409 {
                throw NetworkError.serverError("请求被服务端拒绝，请关闭代理 / VPN 后重试")
            }
            if http.statusCode == 401 { throw NetworkError.unauthorized }
            if !(200...299).contains(http.statusCode) {
                let msg = Self.message(from: data) ?? "上传失败（\(http.statusCode)）"
                NSLog("[NekoAPI] POST %@ -> %d %@", url, http.statusCode, msg)
                throw NetworkError.serverError(msg)
            }
            return data
        }

        throw NetworkError.serverBusy
    }

    // MARK: - Core

    private func send(url: String, method: String, body: Data?, token: String?) async throws -> Data {
        guard let requestURL = URL(string: url) else {
            throw NetworkError.invalidURL
        }

        let path = requestURL.path
        let rawQuery = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        let needsNonce = APIConfig.requiresNonce(path: path)
        let needsIdentity = APIConfig.requiresClientIdentity(path: path)

        // 两种重试，都必须先把失效的东西换掉，否则重试必然再失败：
        // - 409：nonce 缺失 / 过期 / 重放 → 整池作废，重新解 PoW
        // - 401 + X-Neko-Client-Status: invalid：实例令牌失效 → 重新注册
        var nonceRefreshed = false
        var identityRefreshed = false

        for _ in 0..<3 {
            var request = URLRequest(url: requestURL)
            request.httpMethod = method
            request.timeoutInterval = 60

            for (key, value) in APIConfig.clientHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if method != "GET" {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let token = token {
                request.setValue(token, forHTTPHeaderField: "Authorization")
            }
            if let body = body {
                request.httpBody = body
            }

            var nonce = ""
            if needsNonce {
                nonce = try await NonceService.shared.nextNonce(forWrite: method != "GET")
                request.setValue(nonce, forHTTPHeaderField: "X-Neko-Nonce")
            }

            if needsIdentity {
                do {
                    let headers = try await ClientIdentityService.shared.headers(
                        method: method,
                        path: path,
                        rawQuery: rawQuery,
                        bodyHash: Self.bodyHash(for: body),
                        nonce: nonce
                    )
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                } catch {
                    throw NetworkError.serverError(error.localizedDescription)
                }
            }

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.noData
            }

            if httpResponse.statusCode == 409, !nonceRefreshed {
                nonceRefreshed = true
                await NonceService.shared.invalidatePool()
                continue
            }
            if httpResponse.statusCode == 401,
               httpResponse.value(forHTTPHeaderField: "X-Neko-Client-Status")?.lowercased() == "invalid",
               !identityRefreshed {
                identityRefreshed = true
                await ClientIdentityService.shared.invalidate()
                continue
            }
            if httpResponse.statusCode == 401 {
                throw NetworkError.unauthorized
            }
            if httpResponse.statusCode == 409 {
                // 重试后仍被拒：多半是网络环境不合法（境外代理、来源异常）
                throw NetworkError.serverError("请求被服务端拒绝，请关闭代理 / VPN 后重试")
            }
            if httpResponse.statusCode == 429 {
                throw NetworkError.tooManyRequests
            }
            if httpResponse.statusCode == 503 {
                throw NetworkError.serverBusy
            }
            if !(200...299).contains(httpResponse.statusCode) {
                let msg = Self.message(from: data) ?? "请求失败（\(httpResponse.statusCode)）"
                NSLog("[NekoAPI] %@ %@ -> %d %@", method, url, httpResponse.statusCode, msg)
                throw NetworkError.serverError(msg)
            }

            return data
        }

        throw NetworkError.serverBusy
    }

    /// 签名用的请求体哈希：无体用空哈希，multipart 用固定值
    static func bodyHash(for body: Data?) -> String {
        guard let body, !body.isEmpty else { return ClientIdentityService.emptyBodyHash }
        return ClientIdentityService.sha256Hex(body)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.decodingError(error)
        }
    }

    static func message(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        // `/loser/*` 等接口的错误文案放在 msg 里
        if let msg = json["msg"] as? String, !msg.isEmpty {
            return msg
        }
        if let error = json["error"] as? String, !error.isEmpty {
            return error
        }
        return nil
    }
}
