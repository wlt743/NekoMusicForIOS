import Foundation
import CryptoKit
import Security

enum ClientIdentityError: Error, LocalizedError {
    case keyUnavailable
    case badResponse
    case registerFailed(String)
    case signFailed(String)

    var errorDescription: String? {
        switch self {
        case .keyUnavailable: return "客户端身份不可用"
        case .badResponse: return "客户端身份校验失败"
        case .registerFailed(let m): return m
        case .signFailed(let m): return m
        }
    }
}

/// 后端 2026-10 起要求「客户端身份」：每次动态请求都要带
/// Client ID、实例 UUID、实例短期令牌，并对请求签名。
///
/// 流程：
/// 1. 首次启动生成本机 EC P-256 私钥（Keychain 保存，不出本机）
/// 2. `GET /api/client/challenge` 拿一次性挑战
/// 3. `POST /api/client/register` 用私钥签名注册，换实例令牌
/// 4. 令牌到期前用 `POST /api/client/token` 续签
/// 5. 每个请求用同一把私钥签名
///
/// 参考：NekoMusicDocs `API-客户端身份与Client-ID.md`
actor ClientIdentityService {
    static let shared = ClientIdentityService()

    private let clientID = APIConfig.clientID
    private let platform = APIConfig.clientPlatform

    private var privateKey: P256.Signing.PrivateKey?
    private var instanceID: String?
    private var instanceToken: String?
    private var tokenExpiresAt: Date?
    private var inFlight: Task<Void, Error>?
    private var loaded = false

    /// 提前多久续签
    private let renewMargin: TimeInterval = 600

    private let keyService = "com.wlt743.nekomusic.client-identity"
    private let keyAccount = "instance-key"
    private let idAccount = "instance-id"
    private let tokenKey = "nekomusic.client.instance.token"
    private let expiryKey = "nekomusic.client.instance.expiry"

    /// 无请求体的哈希（GET/HEAD/DELETE）
    static let emptyBodyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    /// multipart/form-data 固定值
    static let multipartBodyHash = "-"

    private init() {}

    // MARK: - 对外

    /// 生成某个请求的身份头。调用前必须先拿到 nonce（签名串包含 nonce）。
    func headers(method: String, path: String, rawQuery: String, bodyHash: String, nonce: String) async throws -> [String: String] {
        try await ensureToken()
        guard
            let key = privateKey,
            let iid = instanceID,
            let token = instanceToken
        else {
            throw ClientIdentityError.keyUnavailable
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let signed = [
            "neko-client-v1",
            method.uppercased(),
            path,
            rawQuery,
            clientID,
            iid,
            platform,
            String(timestamp),
            bodyHash,
            nonce,
        ].joined(separator: "\n")

        let signature: Data
        do {
            signature = try key.signature(for: Data(signed.utf8)).derRepresentation
        } catch {
            throw ClientIdentityError.signFailed("\(error)")
        }

        return [
            "X-Neko-Client-Id": clientID,
            "X-Neko-Client-Instance": iid,
            "X-Neko-Client-Token": token,
            "X-Neko-Client-Timestamp": String(timestamp),
            "X-Neko-Client-Signature": Self.base64url(signature),
        ]
    }

    /// 服务端返回 `X-Neko-Client-Status: invalid` 时调用：丢掉令牌重新注册。
    func invalidate() {
        NSLog("[NekoIdentity] invalidate token")
        instanceToken = nil
        tokenExpiresAt = nil
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: expiryKey)
    }

    /// 切换接口服务器时调用：实例与令牌都绑定在原来的服务器上，
    /// 换服务器必须整体作废，否则新服务器会认为实例非法。
    func resetForNewServer() {
        invalidate()
        instanceID = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: idAccount,
        ]
        SecItemDelete(query as CFDictionary)
        NSLog("[NekoIdentity] reset for new server")
    }

    /// 供调试：当前实例 ID
    func currentInstanceID() -> String? {
        loadIfNeeded()
        return instanceID
    }

    // MARK: - 令牌生命周期

    private func ensureToken() async throws {
        loadIfNeeded()
        if let token = instanceToken, !token.isEmpty,
           let expiry = tokenExpiresAt, expiry.timeIntervalSinceNow > renewMargin {
            return
        }

        if let task = inFlight {
            try await task.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.registerOrRenew()
        }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }

    private func registerOrRenew() async throws {
        if instanceID != nil, let token = instanceToken, !token.isEmpty {
            do {
                try await renewToken()
                return
            } catch {
                NSLog("[NekoIdentity] renew failed, fallback to register: %@", "\(error)")
                invalidate()
            }
        }
        try await register()
    }

    // MARK: - 注册 / 续签

    private func register() async throws {
        let key = try ensureKey()
        let iid = try ensureInstanceID()

        let challenge = try await fetchChallenge(purpose: "register")
        let timestamp = Int(Date().timeIntervalSince1970)
        let publicKey = Self.base64url(Self.spkiDer(for: key.publicKey))

        let signed = [
            "neko-client-register-v1",
            clientID,
            platform,
            iid,
            publicKey,
            challenge,
            String(timestamp),
        ].joined(separator: "\n")

        let signature: Data
        do {
            signature = try key.signature(for: Data(signed.utf8)).derRepresentation
        } catch {
            throw ClientIdentityError.signFailed("\(error)")
        }

        let body: [String: Any] = [
            "client_id": clientID,
            "platform": platform,
            "instance_id": iid,
            "public_key": publicKey,
            "challenge": challenge,
            "timestamp": timestamp,
            "signature": Self.base64url(signature),
        ]

        let json = try await postJSON(path: "/api/client/register", body: body)
        guard
            let data = json["data"] as? [String: Any],
            let token = data["token"] as? String, !token.isEmpty,
            let expiresAt = data["expires_at"] as? Int
        else {
            throw ClientIdentityError.registerFailed(Self.message(from: json) ?? "客户端注册失败")
        }

        instanceToken = token
        tokenExpiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAt))
        UserDefaults.standard.set(token, forKey: tokenKey)
        UserDefaults.standard.set(expiresAt, forKey: expiryKey)
        NSLog("[NekoIdentity] registered instance=%@ expires=%ld attestation=%@",
              iid, expiresAt, (data["attestation"] as? String) ?? "-")
    }

    private func renewToken() async throws {
        guard let key = privateKey, let iid = instanceID else {
            throw ClientIdentityError.keyUnavailable
        }

        let challenge = try await fetchChallenge(purpose: "token")
        let timestamp = Int(Date().timeIntervalSince1970)

        let signed = [
            "neko-client-token-v1",
            clientID,
            platform,
            iid,
            challenge,
            String(timestamp),
        ].joined(separator: "\n")

        let signature: Data
        do {
            signature = try key.signature(for: Data(signed.utf8)).derRepresentation
        } catch {
            throw ClientIdentityError.signFailed("\(error)")
        }

        let body: [String: Any] = [
            "client_id": clientID,
            "platform": platform,
            "instance_id": iid,
            "challenge": challenge,
            "timestamp": timestamp,
            "signature": Self.base64url(signature),
        ]

        let json = try await postJSON(path: "/api/client/token", body: body)
        guard
            let data = json["data"] as? [String: Any],
            let token = data["token"] as? String, !token.isEmpty,
            let expiresAt = data["expires_at"] as? Int
        else {
            throw ClientIdentityError.registerFailed(Self.message(from: json) ?? "实例令牌续签失败")
        }

        instanceToken = token
        tokenExpiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAt))
        UserDefaults.standard.set(token, forKey: tokenKey)
        UserDefaults.standard.set(expiresAt, forKey: expiryKey)
        NSLog("[NekoIdentity] renewed instance=%@ expires=%ld", iid, expiresAt)
    }

    private func fetchChallenge(purpose: String) async throws -> String {
        var components = URLComponents(string: APIConfig.clientChallengeURL())!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "purpose", value: purpose),
        ]
        guard let url = components.url else { throw ClientIdentityError.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (key, value) in APIConfig.clientHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientIdentityError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard http.statusCode == 200,
              let payload = json["data"] as? [String: Any],
              let challenge = payload["challenge"] as? String else {
            throw ClientIdentityError.registerFailed(Self.message(from: json) ?? "获取客户端挑战失败（\(http.statusCode)）")
        }
        return challenge
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: APIConfig.baseURL + path) else {
            throw ClientIdentityError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        for (key, value) in APIConfig.clientHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientIdentityError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard http.statusCode == 200 else {
            throw ClientIdentityError.registerFailed(Self.message(from: json) ?? "客户端身份请求失败（\(http.statusCode)）")
        }
        return json
    }

    // MARK: - 本机密钥与实例 ID

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        if let raw = Self.keychainData(service: keyService, account: keyAccount),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            privateKey = key
        }
        if let data = Self.keychainData(service: keyService, account: idAccount),
           let id = String(data: data, encoding: .utf8) {
            instanceID = id
            if let token = UserDefaults.standard.string(forKey: tokenKey), !token.isEmpty {
                instanceToken = token
                let expiry = UserDefaults.standard.integer(forKey: expiryKey)
                tokenExpiresAt = expiry > 0 ? Date(timeIntervalSince1970: TimeInterval(expiry)) : nil
            }
        }
    }

    private func ensureKey() throws -> P256.Signing.PrivateKey {
        loadIfNeeded()
        if let key = privateKey { return key }

        let key = P256.Signing.PrivateKey()
        guard Self.saveKeychain(data: key.rawRepresentation, service: keyService, account: keyAccount) else {
            throw ClientIdentityError.keyUnavailable
        }
        privateKey = key
        NSLog("[NekoIdentity] generated new instance key")
        return key
    }

    private func ensureInstanceID() throws -> String {
        loadIfNeeded()
        if let id = instanceID { return id }

        let id = UUID().uuidString.lowercased()
        guard let data = id.data(using: .utf8),
              Self.saveKeychain(data: data, service: keyService, account: idAccount) else {
            throw ClientIdentityError.keyUnavailable
        }
        instanceID = id
        return id
    }

    // MARK: - 编码工具

    /// P-256 SPKI DER：固定前缀 + 65 字节未压缩公钥点
    private static func spkiDer(for publicKey: P256.Signing.PublicKey) -> Data {
        let header: [UInt8] = [
            0x30, 0x59,
            0x30, 0x13,
            0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00,
        ]
        return Data(header) + publicKey.x963Representation
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func message(from json: [String: Any]) -> String? {
        if let message = json["message"] as? String, !message.isEmpty { return message }
        if let error = json["error"] as? String, !error.isEmpty { return error }
        return nil
    }

    // MARK: - Keychain

    private static func keychainQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainData(service: String, account: String) -> Data? {
        var query = keychainQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private static func saveKeychain(data: Data, service: String, account: String) -> Bool {
        var query = keychainQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            NSLog("[NekoIdentity] keychain save failed: %d", status)
            return false
        }
        query.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess {
            NSLog("[NekoIdentity] keychain add failed: %d", addStatus)
        }
        return addStatus == errSecSuccess
    }
}
