import Foundation

enum VideoRenderStatus: String {
    case idle
    case pending
    case processing
    case done
    case failed

    var text: String {
        switch self {
        case .idle: return "准备中"
        case .pending: return "排队中"
        case .processing: return "渲染中"
        case .done: return "已完成"
        case .failed: return "渲染失败"
        }
    }
}

/// 分享视频渲染：创建任务 → 轮询状态 → 下载成片
@MainActor
final class VideoRenderService: ObservableObject {
    @Published private(set) var status: VideoRenderStatus = .idle
    @Published private(set) var jobId: String?
    @Published private(set) var durationSec: Int = 15
    @Published private(set) var remainingToday: Int?
    @Published private(set) var videoURL: URL?
    @Published var errorMessage: String?
    @Published var notice: String?

    private var pollTask: Task<Void, Never>?

    func reset() {
        pollTask?.cancel()
        pollTask = nil
        status = .idle
        jobId = nil
        videoURL = nil
        errorMessage = nil
        notice = nil
    }

    /// 创建渲染任务，非 VIP 会带水印且限制 15 秒
    func create(musicId: Int, token: String) async {
        reset()
        status = .pending

        do {
            let raw = try await NetworkService.shared.rawPost(
                url: APIConfig.videoRenderCreateURL(),
                json: ["musicId": musicId, "startSec": 0, "watermarked": true],
                token: token
            )

            guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let success = json["success"] as? Bool, success,
                  let data = json["data"] as? [String: Any],
                  let id = data["jobId"] as? String else {
                errorMessage = Self.message(from: raw) ?? "创建渲染任务失败"
                status = .failed
                return
            }

            jobId = id
            durationSec = data["durationSec"] as? Int ?? 15
            remainingToday = data["remainingToday"] as? Int
            notice = json["message"] as? String
            status = .processing

            startPolling(token: token)
        } catch {
            errorMessage = error.localizedDescription
            status = .failed
        }
    }

    private func startPolling(token: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<80 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                guard let id = self.jobId else { return }

                do {
                    let raw = try await NetworkService.shared.rawGet(
                        url: APIConfig.videoRenderStatusURL(jobId: id),
                        token: token
                    )
                    guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                          let data = json["data"] as? [String: Any],
                          let rawStatus = data["status"] as? String else { continue }

                    switch rawStatus {
                    case "done":
                        self.status = .done
                        self.notice = "渲染完成，可以保存或分享"
                        await self.download(token: token)
                        return
                    case "failed":
                        self.status = .failed
                        self.errorMessage = "渲染失败，请稍后重试"
                        return
                    default:
                        self.status = .processing
                    }
                } catch {
                    // 网络抖动继续轮询
                    continue
                }
            }
            self.status = .failed
            self.errorMessage = "渲染超时，稍后可在邮件里查看结果"
        }
    }

    func download(token: String) async {
        guard let id = jobId else { return }
        do {
            let data = try await NetworkService.shared.rawGet(
                url: APIConfig.videoRenderDownloadURL(jobId: id),
                token: token
            )
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("nekomusic-\(id).mp4")
            try data.write(to: fileURL)
            videoURL = fileURL
        } catch {
            errorMessage = "下载成片失败：\\(error.localizedDescription)"
        }
    }

    private static func message(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["message"] as? String
    }
}
