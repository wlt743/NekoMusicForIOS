import Foundation
import CryptoKit

enum NonceError: Error, LocalizedError {
    case serverBusy
    case solveTimeout
    case badResponse

    var errorDescription: String? {
        switch self {
        case .serverBusy: return "服务器繁忙，请稍后再试"
        case .solveTimeout: return "网络繁忙，请稍后重试"
        case .badResponse: return "请求校验失败"
        }
    }
}

/// 负责与后端完成「换题 → 解题 → 兑换 nonce」的流程。
///
/// 后端对所有动态接口要求一次性请求头 `X-Neko-Nonce`，并且 nonce 不能直接领，
/// 必须先解一道 SHA-256 前导零比特的工作量证明题。这里缓存读 / 写两类 nonce 池，
/// 用尽时再批量领取。
actor NonceService {
    static let shared = NonceService()

    private var readNonces: [String] = []
    private var writeNonces: [String] = []
    private var refreshing: Task<Void, Error>?

    private let batchSize = 16
    private let maxSolveSeconds: TimeInterval = 8
    /// nonce 短时有效，取回来后超过这个时间就丢弃重领
    private let maxNonceAge: TimeInterval = 40
    private var fetchedAt: Date = .distantPast

    private init() {}

    /// 取一个未被使用过的 nonce。读请求用 read 池，写请求用 write 池。
    func nextNonce(forWrite: Bool) async throws -> String {
        if let nonce = takeNonce(forWrite: forWrite) {
            return nonce
        }

        try await refreshIfNeeded()

        if let nonce = takeNonce(forWrite: forWrite) {
            return nonce
        }
        throw NonceError.badResponse
    }

    private func takeNonce(forWrite: Bool) -> String? {
        if forWrite {
            return writeNonces.popLast()
        }
        return readNonces.popLast()
    }

    /// 收到 409（nonce 缺失 / 过期 / 重放）时调用：清空池子，强制重新换题解题。
    ///
    /// 只用池里下一个 nonce 重试是不够的——如果整池都是同一批领回来的，
    /// 它们会一起过期，重试还是 409。所以必须整池作废、重新解一道 PoW。
    func invalidatePool() {
        NSLog("[NekoNonce] invalidate pool (\(readNonces.count)/\(writeNonces.count) 作废)")
        readNonces.removeAll()
        writeNonces.removeAll()
        fetchedAt = .distantPast
    }

    private func refreshIfNeeded() async throws {
        if let task = refreshing {
            try await task.value
            return
        }

        // 过期的 nonce 不再使用
        if Date().timeIntervalSince(fetchedAt) > maxNonceAge {
            readNonces.removeAll()
            writeNonces.removeAll()
        }

        let needRead = max(0, batchSize - readNonces.count)
        let needWrite = max(0, batchSize - writeNonces.count)
        guard needRead > 0 || needWrite > 0 else { return }

        let task = Task { [needRead, needWrite] in
            try await self.fetchNoncesWithRetry(read: needRead, write: needWrite)
        }
        refreshing = task

        defer { refreshing = nil }
        try await task.value
    }

    private func fetchNoncesWithRetry(read: Int, write: Int) async throws {
        var attempt = 0
        while true {
            do {
                try await fetchNonces(read: read, write: write)
                fetchedAt = Date()
                NSLog("[NekoNonce] pool read=%d write=%d", readNonces.count, writeNonces.count)
                return
            } catch {
                attempt += 1
                NSLog("[NekoNonce] fetch failed (attempt %d): %@", attempt, "\(error)")
                if attempt >= 3 { throw NonceError.serverBusy }
                // 服务端会按频率加压，退避后再试
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
    }

    private func fetchNonces(read: Int, write: Int) async throws {
        // 1. 换题
        var challengeComponents = URLComponents(string: APIConfig.replayChallengeURL())!
        challengeComponents.queryItems = [
            URLQueryItem(name: "read", value: String(read)),
            URLQueryItem(name: "write", value: String(write)),
        ]

        let challengeData = try await request(url: challengeComponents.url!)
        guard
            let json = try? JSONSerialization.jsonObject(with: challengeData) as? [String: Any],
            let success = json["success"] as? Bool, success,
            let data = json["data"] as? [String: Any],
            let challenge = data["challenge"] as? String,
            let seed = data["seed"] as? String,
            let difficulty = data["difficulty"] as? Int,
            let algorithm = data["algorithm"] as? String
        else {
            throw NonceError.badResponse
        }

        // 遇到不认识的算法不要盲解，直接重新换题
        guard algorithm == "sha256-leading-zero-bits" else {
            throw NonceError.badResponse
        }

        // 2. 解题（放到后台线程，避免卡住界面）
        let proof = try await Task.detached(priority: .userInitiated) {
            try Self.solve(seed: seed, difficulty: difficulty, timeout: 8)
        }.value

        // 3. 兑换 nonce
        var nonceComponents = URLComponents(string: APIConfig.replayNonceURL())!
        nonceComponents.queryItems = [
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "proof", value: String(proof)),
            URLQueryItem(name: "read", value: String(read)),
            URLQueryItem(name: "write", value: String(write)),
        ]

        let nonceData = try await request(url: nonceComponents.url!)
        guard
            let nonceJSON = try? JSONSerialization.jsonObject(with: nonceData) as? [String: Any],
            let nonceSuccess = nonceJSON["success"] as? Bool, nonceSuccess,
            let payload = nonceJSON["data"] as? [String: Any],
            let nonces = payload["nonces"] as? [String: Any]
        else {
            throw NonceError.badResponse
        }

        if let reads = nonces["read"] as? [String] {
            readNonces.append(contentsOf: reads)
        }
        if let writes = nonces["write"] as? [String] {
            writeNonces.append(contentsOf: writes)
        }
    }

    private func request(url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        for (key, value) in APIConfig.clientHeaders {
            req.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 || http.statusCode == 503 {
                throw NonceError.serverBusy
            }
            if http.statusCode != 200 {
                throw NonceError.badResponse
            }
        }
        return data
    }

    // MARK: - Proof of work

    private nonisolated static func solve(seed: String, difficulty: Int, timeout: TimeInterval) throws -> Int {
        // 难度由服务端动态下发，没有固定上限。超出可解范围时必须退避，不能硬解。
        guard difficulty <= 26 else { throw NonceError.solveTimeout }

        let deadline = Date().addingTimeInterval(timeout)
        var counter = 0
        while true {
            if leadingZeroBits("\(seed):\(counter)") >= difficulty {
                return counter
            }
            counter += 1
            if counter % 4096 == 0 && Date() > deadline {
                throw NonceError.solveTimeout
            }
            if counter > 200_000_000 {
                throw NonceError.solveTimeout
            }
        }
    }

    private nonisolated static func leadingZeroBits(_ string: String) -> Int {
        let digest = SHA256.hash(data: Data(string.utf8))
        var bits = 0
        for byte in digest {
            if byte == 0 {
                bits += 8
                continue
            }
            bits += 8 - byte.bitLength
            break
        }
        return bits
    }
}

private extension UInt8 {
    var bitLength: Int {
        var value = self
        var length = 0
        while value > 0 {
            length += 1
            value >>= 1
        }
        return length
    }
}
