import Foundation
import AVFoundation
import CoreHaptics
import QuartzCore
import Combine

/// 音乐震动：分析出「每帧特征」，再由可调参数现场推导重音点。
///
/// 两个设计取舍：
/// 1. 只缓存每帧的频谱通量与分频能量，重音点按当前参数即时推导，
///    这样在 App 里拖滑杆能立刻换手感，不用重新解码；
/// 2. 重击提前排进 pattern，播放中按绝对时间触发，避免现场造播放器的抖动。
final class HapticsService: NSObject, ObservableObject {
    static let shared = HapticsService()

    struct Onset {
        let time: TimeInterval
        let strength: Float
        let sharpness: Float
        let accented: Bool
    }

    struct Frame {
        let flux: Float      // 起音强度
        let low: Float       // <120Hz，鼓/贝斯
        let mid: Float       // 120Hz~2kHz，人声/乐器
        let high: Float      // >2kHz，镲/嘶声/噪声
        /// 音色亮度 0…1：越高越"呲"（火焰、嘶声、镲）
        let brightness: Float
        /// 噪声性 0…1：频谱越平越像噪声（火焰、风声）
        let noisiness: Float
    }

    struct Tuning: Codable, Equatable {
        var sensitivity: Double = 1.2
        var minGap: Double = 0.10
        var strength: Double = 1.0
        var sharpness: Double = 0.75
        var bed: Double = 0.7
        /// 连续层打底强度：安静段落也保持多少震动
        var floor: Double = 0.32

        static let standard = Tuning()
        /// 应用默认手感：偏强烈的方向
        static let appDefault = Tuning.extreme
        /// 柔和：点少、偏闷、打底轻，适合睡前听
        static let soft = Tuning(sensitivity: 1.9, minGap: 0.14, strength: 0.9,
                                 sharpness: 0.5, bed: 0.45, floor: 0.14)
        /// 强烈：点多、偏脆、打底明确，适合快歌
        static let intense = Tuning(sensitivity: 0.85, minGap: 0.08, strength: 1.5,
                                    sharpness: 0.95, bed: 0.85, floor: 0.32)
        /// 超强：在强烈基础上再顶一档，打底更实、重击直接压满马达
        static let extreme = Tuning(sensitivity: 0.8, minGap: 0.07, strength: 1.75,
                                    sharpness: 1.0, bed: 1.0, floor: 0.46)

        static func preset(named name: String) -> Tuning {
            switch name {
            case "柔和": return .soft
            case "强烈": return .intense
            case "超强": return .extreme
            default: return .standard
            }
        }
    }

    private enum Keys {
        static let enabled = "neko.haptics.enabled"
        static let intensity = "neko.haptics.intensity"
    }

    private static let fps: Double = 60
    private static let window: TimeInterval = 4.0
    private static let loopDuration: TimeInterval = 2.0

    var positionProvider: (() -> TimeInterval)?

    @Published private(set) var isSupported: Bool
    @Published private(set) var isAnalyzing: Bool = false
    @Published private(set) var onsetCount: Int = 0
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                startEngine(); startTracking(); rescheduleAccents(force: true)
            } else {
                stopTracking(); stopPlayers()
            }
        }
    }
    @Published var intensity: Double {
        didSet { UserDefaults.standard.set(intensity, forKey: Keys.intensity) }
    }
    /// 用户自存的 4 个预设槽，键为 "1"…"4"
    @Published private(set) var customPresets: [String: Tuning] = [:]

    /// 把当前手感存进某个槽
    func saveCustom(slot: Int) {
        customPresets[String(slot)] = tuning
        persistCustom()
        Self.note("custom preset saved slot=\(slot)")
    }

    func customPreset(slot: Int) -> Tuning? { customPresets[String(slot)] }

    func applyCustom(slot: Int) {
        guard let saved = customPresets[String(slot)] else { return }
        tuning = saved
        Self.note("apply slot=\(slot) floor=\(saved.floor) bed=\(saved.bed) strength=\(saved.strength)")
    }

    func deleteCustom(slot: Int) {
        customPresets.removeValue(forKey: String(slot))
        persistCustom()
    }

    private func persistCustom() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: "neko.haptics.customPresets")
        }
    }

    @Published var tuning: Tuning {
        didSet {
            if let data = try? JSONEncoder().encode(tuning) {
                UserDefaults.standard.set(data, forKey: "neko.haptics.tuning")
            }
            rebuildOnsets()
        }
    }

    private var engine: CHHapticEngine?
    private var bedPlayer: CHHapticAdvancedPatternPlayer?
    private var accentPlayer: CHHapticAdvancedPatternPlayer?
    private var frames: [Frame] = []
    private var loudnessReference: Float = 0.001
    private var onsets: [Onset] = []
    private var link: CADisplayLink?
    private var analysisTask: Task<Void, Never>?
    private var trackKey = ""
    /// 当前曲名，只用于面板上展示
    @Published private(set) var currentTitle = ""
    private var windowStart: TimeInterval = -1
    private var lastPushed: Float = -1
    private var lastSharpness: Float = -1
    private var tickLogCount = 0
    private var lastPosition: TimeInterval = -1

    private override init() {
        let defaults = UserDefaults.standard
        let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        isSupported = supported
        isEnabled = defaults.object(forKey: Keys.enabled) == nil
            ? supported
            : defaults.bool(forKey: Keys.enabled)
        intensity = min(1.4, max(0.4, (defaults.object(forKey: Keys.intensity) as? Double) ?? 1.0))
        if let data = defaults.data(forKey: "neko.haptics.customPresets"),
           let saved = try? JSONDecoder().decode([String: Tuning].self, from: data) {
            customPresets = saved
        }
        if let data = defaults.data(forKey: "neko.haptics.tuning"),
           let saved = try? JSONDecoder().decode(Tuning.self, from: data) {
            tuning = saved
        } else {
            tuning = .appDefault
        }
        super.init()
    }

    // MARK: - 供播放器调用

    func attach(url: URL, trackKey: String, title: String = "") {
        self.trackKey = trackKey
        currentTitle = title
        frames = []
        onsets = []
        onsetCount = 0
        windowStart = -1
        lastPushed = -1
        lastPosition = -1
        analysisTask?.cancel()

        guard isSupported, isEnabled else {
            Self.note("attach skipped supported=\(isSupported) enabled=\(isEnabled)")
            return
        }
        isAnalyzing = true
        analysisTask = Task.detached(priority: .utility) { [weak self] in
            let result = Self.analyse(url: url)
            await MainActor.run { [weak self] in
                guard let self, self.trackKey == trackKey else { return }
                self.frames = result.frames
                self.loudnessReference = result.reference
                self.isAnalyzing = false
                Self.note("analysis frames=\(result.frames.count) ref=\(String(format: "%.3f", result.reference))")
                self.rebuildOnsets()
            }
        }
    }

    func play() {
        guard isSupported, isEnabled else { return }
        startEngine()
        startTracking()
        if tuning.bed > 0 { startBedPlayer() }
        rescheduleAccents(force: true)
    }

    func pause() {
        stopTracking()
        stopPlayers()
    }

    func stop() {
        pause()
        frames = []
        onsets = []
        analysisTask?.cancel()
        isAnalyzing = false
    }

    func seeked(to position: TimeInterval) {
        lastPosition = position
        rescheduleAccents(force: true)
    }

    /// 按当前参数重新推导重音点。
    func rebuildOnsets() {
        guard !frames.isEmpty else { onsets = []; onsetCount = 0; return }
        onsets = Self.derive(frames: frames, tuning: tuning)
        onsetCount = onsets.count
        windowStart = -1
        Self.note("onsets=\(onsets.count) sens=\(String(format: "%.2f", tuning.sensitivity)) gap=\(String(format: "%.2f", tuning.minGap)) floor=\(String(format: "%.2f", tuning.floor)) bed=\(String(format: "%.2f", tuning.bed))")
        if isEnabled { rescheduleAccents(force: true) }
        if tuning.bed > 0, bedPlayer == nil, isEnabled { startBedPlayer() }
        if tuning.bed == 0 { stopBedPlayer() }
    }

    func playTest() {
        startEngine()
        guard let engine else { Self.note("test: engine unavailable"); return }
        let events = (0..<3).map { index in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
                ],
                relativeTime: Double(index) * 0.16
            )
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
            Self.note("test pattern played")
        } catch {
            Self.note("test failed: \(error)")
        }
    }

    // MARK: - 引擎与播放器

    private func startEngine() {
        if let engine { try? engine.start(); return }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self] in
                Task { @MainActor in try? self?.engine?.start() }
            }
            try engine.start()
            self.engine = engine
            Self.note("engine started")
        } catch {
            Self.note("engine start failed: \(error)")
            engine = nil
        }
    }

    private func stopPlayers() {
        stopBedPlayer()
        try? accentPlayer?.stop(atTime: CHHapticTimeImmediate)
        accentPlayer = nil
        windowStart = -1
    }

    private func stopBedPlayer() {
        try? bedPlayer?.stop(atTime: CHHapticTimeImmediate)
        bedPlayer = nil
    }

    private func startBedPlayer() {
        guard bedPlayer == nil, let engine else { return }
        do {
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
                ],
                relativeTime: 0,
                duration: Self.loopDuration
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            try player.start(atTime: CHHapticTimeImmediate)
            bedPlayer = player
        } catch {
            Self.note("bed player failed: \(error)")
            bedPlayer = nil
        }
    }

    private func rescheduleAccents(force: Bool) {
        guard isEnabled, isSupported, let engine, !onsets.isEmpty else { return }
        guard let position = positionProvider?(), position.isFinite, position >= 0 else { return }
        if !force, windowStart >= 0, position - windowStart < Self.window - 1.2 { return }

        let upcoming = onsets.filter { $0.time >= position - 0.02 && $0.time < position + Self.window }
        windowStart = position
        guard !upcoming.isEmpty else { accentPlayer = nil; return }

        let events = upcoming.map { onset -> CHHapticEvent in
            let base = Double(onset.strength) * tuning.strength * intensity * 1.6
            // 普通点保底 0.8；超强档连普通点也往满推；节拍点直接顶格
            let floorValue = tuning.floor > 0.4 ? 0.94 : 0.8
            let value = Float(onset.accented ? 1.0 : min(1.0, max(floorValue, base)))
            let sharp = Float(min(1.0, max(0.3, Double(onset.sharpness) + (tuning.sharpness - 0.75))))
            return CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: value),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharp),
                ],
                relativeTime: max(0, onset.time - position)
            )
        }
        do {
            try? accentPlayer?.stop(atTime: CHHapticTimeImmediate)
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            accentPlayer = player
        } catch {
            Self.note("accent schedule failed: \(error)")
            accentPlayer = nil
        }
    }

    // MARK: - 逐帧

    private func startTracking() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopTracking() {
        link?.invalidate()
        link = nil
        lastPosition = -1
        lastPushed = -1
    }

    @objc private func tick() {
        guard isEnabled, isSupported else { return }
        guard let position = positionProvider?(), position.isFinite, position >= 0 else { return }

        if lastPosition >= 0, position < lastPosition - 0.3 || position > lastPosition + 1.0 {
            rescheduleAccents(force: true)
        }
        lastPosition = position

        if windowStart < 0 || position - windowStart > Self.window - 1.2 {
            rescheduleAccents(force: true)
        }

        guard let bedPlayer, !frames.isEmpty else { return }
        let index = Int(position * Self.fps)
        guard index >= 0, index < frames.count else { return }
        let frame = frames[index]

        // 亮度 → 锐度：高频噪声（火焰、嘶声、镲）给高锐度，低频给低锐度
        let sharpness = Float(min(1.0, max(0.15, Double(frame.noisiness) * 0.75
            + Double(frame.brightness) * 0.35 + tuning.sharpness - 0.75)))
        // 响度 → 强度
        // 打底 32%：安静段也有持续的存在感，响的地方直接顶格
        let floorLevel = Float(tuning.floor)
        let loudness = Float(Double(frame.low) * 0.6 + Double(frame.mid) * 0.25 + Double(frame.high) * 0.5)
        let normalized = min(1, loudness / max(loudnessReference, 0.0001))
        // bed 直接作为 0…1 的整体权重，不再二次放大，否则所有档位都会顶到 1.0
        let level = min(1.0, (floorLevel + (1 - floorLevel) * normalized)
            * Float(intensity) * Float(tuning.bed))

        guard abs(level - lastPushed) > 0.015 || abs(sharpness - lastSharpness) > 0.05 else { return }
        lastPushed = level
        lastSharpness = sharpness
        let parameters = [
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0),
        ]
        try? bedPlayer.sendParameters(parameters, atTime: CHHapticTimeImmediate)
        tickLogCount += 1
        if tickLogCount % 90 == 0 {
            Self.note("tick level=\(String(format: "%.2f", level)) sharp=\(String(format: "%.2f", sharpness)) floor=\(String(format: "%.2f", tuning.floor))")
        }
    }

    // MARK: - 由参数推导重音点

    /// 频谱通量自适应阈值 + BPM 网格重音。
    private static func derive(frames: [Frame], tuning: Tuning) -> [Onset] {
        guard frames.count > 8 else { return [] }
        let flux = frames.map { $0.flux }
        let mean = flux.reduce(0, +) / Float(flux.count)
        let variance = flux.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(flux.count)
        let std = max(variance.squareRoot(), 0.0001)
        let threshold = mean + Float(tuning.sensitivity) * std

        // 估 BPM：对通量做自相关，取 60~200 BPM 的峰
        var bestLag = 0
        var bestScore: Float = 0
        let minLag = Int(fps * 60 / 200)
        let maxLag = Int(fps * 60 / 60)
        if maxLag > minLag, flux.count > maxLag * 2 {
            for lag in minLag...maxLag {
                var score: Float = 0
                var i = 0
                while i + lag < flux.count {
                    score += flux[i] * flux[i + lag]
                    i += 1
                }
                if score > bestScore { bestScore = score; bestLag = lag }
            }
        }
        let beatPeriod = bestLag > 0 ? Double(bestLag) / fps : 0

        var result: [Onset] = []
        var lastTime: TimeInterval = -1
        for i in 3..<flux.count {
            let current = flux[i]
            guard current > threshold else { continue }
            let time = Double(i) / fps
            guard time - lastTime > tuning.minGap else { continue }

            let strength = Float(min(1, current / (threshold * 2.2 + 0.0001)))
            let frame = frames[i]
            let total = frame.low + frame.mid + frame.high
            let highShare = total > 0 ? frame.high / total : 0
            let sharpness = Float(min(1, max(0.3, 0.45 + Double(highShare) * 0.55)))

            // 落在节拍网格上的点给重音，这是"动感"的来源
            var accented = false
            if beatPeriod > 0 {
                let phase = time.truncatingRemainder(dividingBy: beatPeriod)
                let distance = min(phase, beatPeriod - phase)
                accented = distance < 0.07
            }
            result.append(Onset(time: time, strength: strength, sharpness: sharpness, accented: accented))
            lastTime = time
        }
        return result
    }

    // MARK: - 解码与特征提取（后台线程）

    private static func analyse(url: URL) -> (frames: [Frame], reference: Float) {
        if url.isFileURL { return analyseLocal(url: url) }
        guard let local = download(url) else {
            note("download failed, skip haptics")
            return ([], 0.001)
        }
        defer { try? FileManager.default.removeItem(at: local) }
        note("downloaded \(ByteCountFormatter.string(fromByteCount: fileSize(local), countStyle: .file))")
        return analyseLocal(url: local)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private static func download(_ url: URL) -> URL? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
            defer { semaphore.signal() }
            guard let temp, error == nil else {
                note("download error: \(String(describing: error))")
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                note("download status=\(http.statusCode)")
                return
            }
            // 必须保留扩展名：AVURLAsset 靠它识别容器
            let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("neko-haptic-\(UUID().uuidString).\(ext)")
            do {
                try FileManager.default.moveItem(at: temp, to: target)
                box.value = target
            } catch {
                note("move failed: \(error)")
            }
        }
        task.resume()
        semaphore.wait()
        return box.value
    }

    private final class Box {
        var value: URL?
    }

    private static func analyseLocal(url: URL) -> (frames: [Frame], reference: Float) {
        let sampleRate = 22050.0
        let bucket = Int(sampleRate / fps)
        guard bucket > 0 else { return ([], 0.001) }
        guard let (reader, output) = try? makeReader(url: url, sampleRate: sampleRate) else {
            note("reader setup failed")
            return ([], 0.001)
        }

        let lowAlpha: Float = 0.034      // ~120Hz
        let highAlpha: Float = 0.35      // ~2kHz
        var lowLP: Float = 0
        var highLP: Float = 0
        var lowSum: Float = 0
        var highSum: Float = 0
        var totalSum: Float = 0
        var count = 0
        var previousLow: Float = 0
        var previousHigh: Float = 0
        var result: [Frame] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer
            )
            guard status == noErr, let pointer else { continue }
            let samples = length / MemoryLayout<Int16>.size
            let buffer = UnsafeRawPointer(pointer).assumingMemoryBound(to: Int16.self)
            for i in 0..<samples {
                let x = Float(buffer[i]) / 32768
                lowLP += lowAlpha * (x - lowLP)
                highLP += highAlpha * (x - highLP)
                let high = x - highLP
                let mid = highLP - lowLP
                totalSum += x * x
                lowSum += lowLP * lowLP
                highSum += high * high
                count += 1
                if count >= bucket {
                    let low = (lowSum / Float(count)).squareRoot()
                    let high = (highSum / Float(count)).squareRoot()
                    let midValue = (max(totalSum - lowSum - highSum, 0) / Float(count)).squareRoot()
                    // 频谱通量：各频段相对上一帧的正向增长
                    let delta = max(low - previousLow, 0)
                        + max(high - previousHigh, 0) * 1.4
                        + max(midValue - 0, 0) * 0.2
                    let total = low + midValue + high
                    // 亮度：高频占比 + 中频占比的加权
                    let brightness = total > 0.0001 ? min(1, (high * 1.6 + midValue * 0.6) / total) : 0
                    // 噪声性：高频相对低频的富集程度，火焰/风声这类宽带噪声值高
                    let noisiness = total > 0.0001 ? min(1, high / max(low, 0.0002) * 0.35) : 0
                    result.append(Frame(flux: delta, low: low, mid: midValue, high: high,
                                        brightness: brightness, noisiness: noisiness))
                    previousLow = low
                    previousHigh = high
                    totalSum = 0
                    lowSum = 0
                    highSum = 0
                    count = 0
                }
            }
        }
        guard !result.isEmpty else {
            note("decode empty status=\(reader.status.rawValue) error=\(String(describing: reader.error))")
            return ([], 0.001)
        }
        // 整曲响度基准：让副歌能顶到 1.0
        let loudness = result.map { Double($0.low) * 0.6 + Double($0.mid) * 0.25 + Double($0.high) * 0.5 }
        let sortedLoud = loudness.sorted()
        let reference = Float(max(sortedLoud[Int(Double(sortedLoud.count - 1) * 0.95)], 0.0005))
        return (result, reference)
    }

    private static func makeReader(url: URL, sampleRate: Double) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio)
        guard let track = tracks.first else {
            note("no audio track, all=\(asset.tracks.count) ext=\(url.pathExtension)")
            throw NSError(domain: "NekoHaptics", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有音频轨道"])
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            note("cannot add output")
            throw NSError(domain: "NekoHaptics", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法添加音频输出"])
        }
        reader.add(output)
        guard reader.startReading() else {
            note("startReading failed: \(String(describing: reader.error))")
            throw reader.error ?? NSError(domain: "NekoHaptics", code: 3)
        }
        return (reader, output)
    }

    /// 真机排查用：同时写一行到 Documents/neko-haptics.log
    private static func note(_ message: String) {
        NSLog("[NekoHaptics] %@", message)
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("neko-haptics.log") else { return }
        let line = "\n" + message
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
