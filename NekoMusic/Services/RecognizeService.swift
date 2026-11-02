import AVFoundation
import Foundation

enum RecognizeError: LocalizedError {
    case micDenied
    case tooShort

    var errorDescription: String? {
        switch self {
        case .micDenied: return "没有麦克风权限，请到系统设置里打开"
        case .tooShort: return "录音太短，至少录 3 秒"
        }
    }
}

/// 听歌识曲：录一段音频后上传到 /api/music/recognize
@MainActor
final class RecognizeService: ObservableObject {
    static let shared = RecognizeService()

    @Published private(set) var isRecording = false
    @Published private(set) var isRecognizing = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var matched: RecognizedTrack?
    @Published var notice: String?
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    private init() {}

    // MARK: - 录音

    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw RecognizeError.micDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recognize-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else {
            throw RecognizeError.micDenied
        }

        self.recorder = recorder
        fileURL = url
        isRecording = true
        elapsed = 0
        matched = nil
        notice = nil
        errorMessage = nil

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed += 0.1
                // 最长录 20 秒，防止一直开着
                if self.elapsed >= 20 {
                    await self.stopAndRecognize()
                }
            }
        }
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
    }

    // MARK: - 识别

    func stopAndRecognize() async {
        guard isRecording else { return }

        let duration = elapsed
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false

        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else {
            errorMessage = "录音文件不可用"
            return
        }
        try? FileManager.default.removeItem(at: url)
        fileURL = nil

        guard duration >= 3 else {
            errorMessage = RecognizeError.tooShort.errorDescription
            return
        }

        isRecognizing = true
        defer { isRecognizing = false }

        do {
            let raw = try await NetworkService.shared.uploadMultipart(
                url: APIConfig.recognizeURL(),
                fieldName: "audio",
                filename: "sample.m4a",
                mimeType: "audio/mp4",
                fileData: data
            )

            guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                errorMessage = "服务端返回异常"
                return
            }

            let matchedFlag = json["matched"] as? Bool ?? false
            if matchedFlag, let payload = json["data"] as? [String: Any] {
                matched = RecognizedTrack(json: payload)
            } else {
                notice = json["message"] as? String ?? "未在当前曲库中识别到歌曲"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - 识别结果

struct RecognizedTrack: Identifiable {
    let id: Int
    let title: String
    let artist: String
    let album: String
    let duration: Int
    let confidence: Double
    let offsetSeconds: Double

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int,
              let title = json["title"] as? String,
              let artist = json["artist"] as? String else { return nil }
        self.id = id
        self.title = title
        self.artist = artist
        self.album = json["album"] as? String ?? ""
        self.duration = json["duration"] as? Int ?? 0
        self.confidence = json["confidence"] as? Double ?? 0
        self.offsetSeconds = json["offsetSeconds"] as? Double ?? 0
    }

    var asMusic: Music {
        Music(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            filePath: nil,
            coverFilePath: nil,
            uploadUserId: nil,
            createdAt: nil,
            playCount: nil,
            lrc: nil
        )
    }
}
