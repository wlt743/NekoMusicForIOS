import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Combine

enum PlayMode: String, CaseIterable {
    case listLoop = "LIST_LOOP"
    case singleLoop = "SINGLE_LOOP"
    case shuffle = "SHUFFLE"
    
    var icon: String {
        switch self {
        case .listLoop: return "repeat"
        case .singleLoop: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }
    
    var displayName: String {
        switch self {
        case .listLoop: return "列表循环"
        case .singleLoop: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }
}

class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()
    
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    
    @Published var isPlaying: Bool = false
    @Published var currentPosition: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var currentMusic: Music?
    /// 用户主动点歌时置为 true，界面据此自动展开播放页
    @Published var presentNowPlaying = false
    @Published var playMode: PlayMode = .listLoop
    @Published var isFavorite: Bool = false
    @Published var playlist: [Music] = []
    @Published var currentLyrics: String = ""
    private var lyricLines: [(time: TimeInterval, text: String)] = []
    
    private var playHistory: [Int] = []
    private var cancellables = Set<AnyCancellable>()
    private var artworkCache: [Int: MPMediaItemArtwork] = [:]
    /// 锁屏实时活动用的小封面（96px JPEG）
    private var artworkDataCache: [Int: Data] = [:]
    /// 已经同步到锁屏的歌词行，避免每 0.5 秒重复写 nowPlayingInfo
    private var lastPublishedLyricLine: String?
    private var lastInfoSync: Date = .distantPast
    
    private init() {
        // 震动跟拍用同一个时间源，避免和界面上的 0.2s 计时漂移
        HapticsService.shared.positionProvider = { [weak self] in
            guard let self, let player = self.player else { return self?.currentPosition ?? 0 }
            let seconds = CMTimeGetSeconds(player.currentTime())
            return seconds.isFinite ? max(0, seconds) : self.currentPosition
        }
        UIApplication.shared.beginReceivingRemoteControlEvents()
        setupAudioSession()
        setupRemoteTransportControls()
        setupNotifications()
        loadPlayMode()
    }
    
    // MARK: - Audio Session
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: []
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession setup error: \(error)")
        }
    }
    
    // MARK: - Remote Controls (Lock Screen / Control Center)
    
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.play() }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.togglePlayPause() }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.next() }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previous() }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            DispatchQueue.main.async { self?.seekTo(position: position) }
            return .success
        }

        // 不注册「前进/后退 15 秒」：CarPlay 与锁屏改为显示「上一首 / 下一首」。
        // CarPlay 的 Now Playing 会优先展示 skip 命令，禁用后才会落到 next/prev。
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipForwardCommand.preferredIntervals = []
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.preferredIntervals = []
    }

    // MARK: - Now Playing 内容

    /// 当前唱到的歌词行；没有歌词时返回 nil
    private var currentLyricLine: String? {
        guard !lyricLines.isEmpty else { return nil }
        let index = LyricsParser.index(at: currentPosition, in: lyricLines)
        guard index >= 0, index < lyricLines.count else { return nil }
        let text = lyricLines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 当前行 + 前后各一行，给锁屏实时活动用
    private func lyricNeighborhood() -> (previous: String, current: String, next: String) {
        guard !lyricLines.isEmpty else { return ("", "", "") }
        // 提前一点点切换，抵消锁屏渲染延迟
        let index = LyricsParser.index(at: currentPosition + 0.12, in: lyricLines)
        guard index >= 0, index < lyricLines.count else { return ("", "", "") }

        func text(_ i: Int) -> String {
            guard i >= 0, i < lyricLines.count else { return "" }
            return lyricLines[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return (text(index - 1), text(index), text(index + 1))
    }

    /// 锁屏 / 控制中心显示的第二行：有歌词就显示歌词，否则显示歌手
    private func displayArtist(for music: Music) -> String {
        currentLyricLine ?? music.artist
    }

    private func nowPlayingDictionary(for music: Music) -> [String: Any] {
        [
            MPMediaItemPropertyTitle: music.title,
            MPMediaItemPropertyArtist: displayArtist(for: music),
            MPMediaItemPropertyAlbumTitle: music.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentPosition,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyExternalContentIdentifier: "nekomusic:\(music.id)",
            MPNowPlayingInfoPropertyPlaybackQueueCount: playlist.count,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: playlist.firstIndex(where: { $0.id == music.id }) ?? 0,
        ]
    }

    private func updateNowPlayingInfo() {
        guard let music = currentMusic else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if #available(iOS 16.1, *) {
                Task { @MainActor in LyricLiveActivityManager.shared.end() }
            }
            return
        }

        var info = nowPlayingDictionary(for: music)
        if let artwork = artworkCache[music.id] {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        let neighborhood = lyricNeighborhood()
        let playing = isPlaying
        // 歌词还没到 / 解析为空时给个占位，别把卡片刷成空白
        let currentLine: String
        if !neighborhood.current.isEmpty {
            currentLine = neighborhood.current
        } else if currentLyrics.isEmpty {
            currentLine = "正在载入歌词…"
        } else {
            currentLine = "纯音乐，请欣赏"
        }

        if #available(iOS 16.1, *) {
            Task { @MainActor in
                LyricLiveActivityManager.shared.update(
                    title: music.title,
                    artist: music.artist,
                    artworkData: self.artworkDataCache[music.id],
                    previous: neighborhood.previous,
                    current: currentLine,
                    next: neighborhood.next,
                    isPlaying: playing
                )
            }
        }
        lastInfoSync = Date()

        loadArtworkIfNeeded(for: music)
    }

    /// 封面按歌曲缓存，避免每次刷新 Now Playing 都重新下载
    private func loadArtworkIfNeeded(for music: Music) {
        guard artworkCache[music.id] == nil else { return }

        let coverPath = APIConfig.buildMusicCoverURL(musicId: music.id, coverFilePath: music.coverFilePath)
        guard URL(string: coverPath) != nil else { return }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let data = try await NetworkService.shared.fetchData(url: coverPath)
                guard let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

                // 生成锁屏活动用的小图
                let small = Self.smallArtworkData(from: image)

                await MainActor.run {
                    self.artworkCache[music.id] = artwork
                    if let small = small {
                        self.artworkDataCache[music.id] = small
                    }
                    guard self.currentMusic?.id == music.id else { return }

                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info

                    // 封面到了再刷一次活动，卡片才有图
                    self.updateNowPlayingInfo()
                }
            } catch {
                print("Load now playing artwork failed: \(error)")
            }
        }
    }

    /// 把封面压成 96px JPEG，塞进实时活动的状态里
    private static func smallArtworkData(from image: UIImage, maxSide: CGFloat = 48) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.5)
    }

    /// 播放中节流更新进度，保证控制中心/锁屏进度条平滑
    private func syncElapsedTime() {
        updateNowPlayingInfo()
    }

    // MARK: - 音频中断 / 线路变化

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

            switch type {
            case .began:
                self.pause()
            case .ended:
                let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                    self.play()
                }
            @unknown default:
                break
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

            if reason == .oldDeviceUnavailable {
                self.pause()
            }
        }
    }

    // MARK: - Playback Controls
    
    func playMusic(_ music: Music) {
        // 记录历史
        if currentMusic?.id != music.id {
            if let currentId = currentMusic?.id {
                playHistory.append(currentId)
            }
        }

        currentMusic = music
        if #available(iOS 16.1, *) {
            Task { @MainActor in
                LyricLiveActivityManager.shared.start(
                    title: music.title,
                    artist: music.artist,
                    artworkData: self.artworkDataCache[music.id]
                )
                // 歌词可能比活动先到，补刷一次
                try? await Task.sleep(nanoseconds: 800_000_000)
                self.updateNowPlayingInfo()
            }
        }
        duration = 0
        currentPosition = 0
        currentLyrics = ""
        lastPublishedLyricLine = nil

        // 加入当前播放列表
        if !playlist.contains(where: { $0.id == music.id }) {
            playlist.append(music)
        }

        // 后端新接口需要先换取真正的音频地址（带 nonce），拿到后再播放
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let url = try await MusicService.shared.resolveAudioURL(musicId: music.id)
                await MainActor.run {
                    guard self.currentMusic?.id == music.id else { return }
                    self.startPlayback(url: url)
                }
            } catch {
                NSLog("[NekoAPI] resolve audio url failed: %@", String(describing: error))
                await MainActor.run {
                    guard self.currentMusic?.id == music.id else { return }
                    self.isPlaying = false
                }
            }
        }

        updateNowPlayingInfo()
        checkFavoriteStatus()
        loadLyrics()
    }

    private func startPlayback(url: URL) {
        // 换歌时清掉上一首的订阅，避免累积
        cancellables.removeAll()

        playerItem = AVPlayerItem(url: url)

        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }

        // 观察时长
        playerItem?.publisher(for: \.duration)
            .compactMap { $0.isNumeric ? CMTimeGetSeconds($0) : nil }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                self?.duration = dur
                self?.syncElapsedTime()
            }
            .store(in: &cancellables)

        // 观察播放结束
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handlePlaybackEnd()
            }
            .store(in: &cancellables)

        // 开始进度跟踪
        startPositionTracking()

        player?.play()
        isPlaying = true
        updateNowPlayingInfo()

        HapticsService.shared.attach(url: url, trackKey: "\(currentMusic?.id ?? 0)", title: currentMusic?.title ?? "")
        HapticsService.shared.play()
    }
    
    func play() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
        HapticsService.shared.play()
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
        HapticsService.shared.pause()
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func seekTo(position: TimeInterval) {
        let time = CMTime(seconds: position, preferredTimescale: 600)
        player?.seek(to: time)
        currentPosition = position
        updateNowPlayingInfo()
        HapticsService.shared.seeked(to: position)
    }
    
    func next() {
        guard let music = currentMusic else { return }
        
        switch playMode {
        case .listLoop:
            if let index = playlist.firstIndex(where: { $0.id == music.id }) {
                let nextIndex = (index + 1) % playlist.count
                playMusic(playlist[nextIndex])
            }
        case .singleLoop:
            // When user manually presses next, go to next song
            if let index = playlist.firstIndex(where: { $0.id == music.id }) {
                let nextIndex = (index + 1) % playlist.count
                playMusic(playlist[nextIndex])
            }
        case .shuffle:
            let availableMusic = playlist.filter { $0.id != music.id }
            if let randomMusic = availableMusic.randomElement() {
                playMusic(randomMusic)
            }
        }
    }
    
    func previous() {
        guard let music = currentMusic else { return }
        
        // Try to go back in history first
        if let lastId = playHistory.popLast(),
           let previousMusic = playlist.first(where: { $0.id == lastId }) {
            playMusic(previousMusic)
            return
        }
        
        // Otherwise go to previous in list
        if let index = playlist.firstIndex(where: { $0.id == music.id }) {
            let prevIndex = (index - 1 + playlist.count) % playlist.count
            playMusic(playlist[prevIndex])
        }
    }
    
    func togglePlayMode() {
        switch playMode {
        case .listLoop: playMode = .singleLoop
        case .singleLoop: playMode = .shuffle
        case .shuffle: playMode = .listLoop
        }
        savePlayMode()
    }
    
    // MARK: - Playlist Management
    
    func setPlaylist(_ musics: [Music], startAt index: Int = 0) {
        playlist = musics
        if index < musics.count {
            playMusic(musics[index])
        }
        // 点歌即展开播放页，避免“点了没反应”的错觉
        presentNowPlaying = true
    }
    
    // MARK: - Private Methods
    
    private func startPositionTracking() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentPosition = CMTimeGetSeconds(time)

            if Date().timeIntervalSince(self.lastInfoSync) >= 1.0 {
                self.syncElapsedTime()
            }

            // 歌词行变化时同步到锁屏 / 待机显示的第二行
            if let line = self.currentLyricLine, line != self.lastPublishedLyricLine {
                self.lastPublishedLyricLine = line
                self.updateNowPlayingInfo()
            }
        }
    }
    
    private func handlePlaybackEnd() {
        switch playMode {
        case .singleLoop:
            seekTo(position: 0)
            play()
        case .listLoop, .shuffle:
            next()
        }
    }
    
    private func checkFavoriteStatus() {
        guard let music = currentMusic,
              let token = AuthService.shared.token else {
            isFavorite = false
            return
        }
        
        Task {
            let result = await FavoriteService.shared.isFavorited(token: token, musicId: music.id)
            await MainActor.run {
                self.isFavorite = result
            }
        }
    }
    
    func toggleFavorite() {
        guard let music = currentMusic,
              let token = AuthService.shared.token else { return }
        
        Task {
            do {
                if isFavorite {
                    _ = try await FavoriteService.shared.removeFavorite(token: token, musicId: music.id)
                } else {
                    _ = try await FavoriteService.shared.addFavorite(token: token, musicId: music.id)
                }
                await MainActor.run {
                    self.isFavorite.toggle()
                }
            } catch {
                print("Toggle favorite error: \(error)")
            }
        }
    }
    
    private func loadLyrics() {
        guard let music = currentMusic else {
            currentLyrics = ""
            lyricLines = []
            return
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let lyrics = try await MusicService.shared.getLyrics(musicId: music.id)
                await MainActor.run {
                    guard self.currentMusic?.id == music.id else { return }
                    self.currentLyrics = lyrics
                    self.lyricLines = LyricsParser.parse(lyrics)
                    self.updateNowPlayingInfo()
                }
            } catch {
                await MainActor.run {
                    guard self.currentMusic?.id == music.id else { return }
                    self.currentLyrics = ""
                    self.lyricLines = []
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    // MARK: - Persistence
    
    private func loadPlayMode() {
        if let savedMode = UserDefaults.standard.string(forKey: "play_mode"),
           let mode = PlayMode(rawValue: savedMode) {
            playMode = mode
        }
    }
    
    private func savePlayMode() {
        UserDefaults.standard.set(playMode.rawValue, forKey: "play_mode")
    }
}
