import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var playerService: AudioPlayerService
    @EnvironmentObject var appearance: AppearanceSettings
    @ObservedObject private var haptics = HapticsService.shared
    @Binding var isPresented: Bool
    /// 由外部容器显式传入，旋转时才会更新（内部 GeometryReader 在层级里可能拿到 0）
    var containerSize: CGSize = .zero
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var lyricProgress: CGFloat = 0
    @State private var dragStartProgress: CGFloat = 0
    @State private var isDraggingPage = false
    @State private var showComments = false
    @State private var showBlockConfirm = false
    @State private var showSharePanel = false
    @State private var showHapticsTuning = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let size = containerSize.width > 0 ? containerSize : geo.size
                let isLandscape = size.width > size.height
                Group {
                    if isLandscape {
                        landscapeLayout(width: size.width, height: size.height)

                    } else {
                        portraitLayout

                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .foregroundStyle(.white)
            .background {
                coverBackground
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(
                        LinearGradient(
                            colors: [.black, .black.opacity(0.35), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 170)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .tint(.white)
                    .accessibilityLabel("返回")
                }

                if isWideLayout {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSharePanel = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .tint(.white)
                        .disabled(playerService.currentMusic == nil)
                        .accessibilityLabel("分享")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showComments = true
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    .tint(.white)
                    .disabled(playerService.currentMusic == nil)
                    .accessibilityLabel("评论")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        toggleLyrics()
                    } label: {
                        Text("词")
                            .font(.system(size: 17, weight: lyricProgress > 0.5 ? .bold : .regular))
                            .foregroundStyle(lyricProgress > 0.5 ? Color.accentColor : Color.white)
                    }
                    .accessibilityLabel(lyricProgress > 0.5 ? "收起歌词" : "显示歌词")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showSharePanel = true
                        } label: {
                            Label("分享这首歌", systemImage: "square.and.arrow.up")
                        }
                        .disabled(playerService.currentMusic == nil)

                        Button(role: .destructive) {
                            showBlockConfirm = true
                        } label: {
                            Label("拉黑这首歌", systemImage: "hand.raised.slash")
                        }
                        .disabled(playerService.currentMusic == nil)

                        if haptics.isSupported {
                            Button {
                                haptics.isEnabled.toggle()
                            } label: {
                                Label(
                                    haptics.isEnabled ? "关闭音乐震动" : "开启音乐震动",
                                    systemImage: haptics.isEnabled
                                        ? "waveform.circle.fill"
                                        : "waveform.circle"
                                )
                            }

                            if haptics.isEnabled {
                                Button {
                                    haptics.playTest()
                                } label: {
                                    Label("试一下震动", systemImage: "iphone.radiowaves.left.and.right")
                                }

                                Button {
                                    showHapticsTuning = true
                                } label: {
                                    Label("震动手感", systemImage: "slider.horizontal.3")
                                }

                                Menu {
                                    Button("轻柔") { haptics.intensity = 0.6 }
                                    Button("标准") { haptics.intensity = 1.0 }
                                    Button("强烈") { haptics.intensity = 1.4 }
                                } label: {
                                    Label("震动强度", systemImage: "dial.medium")
                                }
                            }
                        }

                        Button {
                            close()
                        } label: {
                            Label("收起播放页", systemImage: "chevron.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .tint(.white)
                    .accessibilityLabel("更多")
                }
            }
            .overlay(alignment: .leading) {
                edgeSwipeArea
            }
        }
        .sheet(isPresented: $showComments) {
            if let music = playerService.currentMusic {
                CommentsView(music: music)
            }
        }
        .sheet(isPresented: $showSharePanel) {
            SharePanelView(text: shareText)
        }
        .sheet(isPresented: $showHapticsTuning) {
            HapticsTuningView(haptics: haptics)
        }
        .confirmationDialog("拉黑这首歌？", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("不再播放《\(playerService.currentMusic?.title ?? "")》", role: .destructive) {
                blockCurrent()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("拉黑后这首歌会从推荐、搜索、歌单和收藏里隐藏，并跳过播放。只保存在本机。")
        }
    }

    /// 折叠屏 / iPad 这类宽屏用工具栏分享，直板机放到歌名右侧
    private var isWideLayout: Bool { horizontalSizeClass == .regular }

    private var shareText: String {
        guard let music = playerService.currentMusic else { return APIConfig.baseURL }
        return "《\(music.title)》- \(music.artist)\n\(APIConfig.baseURL)/detail/\(music.id)"
    }

    private func blockCurrent() {
        guard let music = playerService.currentMusic else { return }
        BlacklistService.shared.block(music)
        playerService.next()
    }

    // MARK: - 竖屏布局

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack {
                    coverPage
                        .offset(x: -lyricProgress * width)
                        .allowsHitTesting(lyricProgress < 0.5)

                    lyricsPage
                        .offset(x: (1 - lyricProgress) * width)
                        .allowsHitTesting(lyricProgress > 0.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(pageDrag(width: width))
                .clipped()
            }
            .padding(.horizontal, 24)

            trackInfo
                .padding(.horizontal, 24)
            progress
                .padding(.horizontal, 24)
            controls
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 24)
    }

    // MARK: - 横屏布局（左封面 / 右信息与控制，参考 Apple Music）

    // MARK: - 布局模式（按 Size Class 选，后续折叠屏/iPad 自动走 wide）

    private enum PlayerLayoutMode {
        case portrait
        case landscape
        case wide
    }

    private var layoutMode: PlayerLayoutMode {
        // iPad / 折叠屏展开：横向空间充裕
        if horizontalSizeClass == .regular { return .wide }
        // iPhone 横屏：垂直方向被压扁
        if verticalSizeClass == .compact { return .landscape }
        return .portrait
    }

    // MARK: - 横屏

    private func landscapeLayout(width: CGFloat, height: CGFloat) -> some View {
        // 用相对比例给左栏定宽，具体内容能否放下交给 ViewThatFits
        let leftWidth = min(width * 0.46, height * 1.1)

        return HStack(spacing: 24) {
            // 从完整到极简四级，保证低矮机型也能完整显示控件
            ViewThatFits(in: .vertical) {
                leftColumn(width: leftWidth, coverSide: 200, compact: false)
                leftColumn(width: leftWidth, coverSide: 170, compact: false)
                leftColumn(width: leftWidth, coverSide: 140, compact: true)
                leftColumn(width: leftWidth, coverSide: 110, compact: true)
                leftColumn(width: leftWidth, coverSide: 84, compact: true)
            }
            .frame(width: leftWidth)

            lyricsPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    /// 左栏：封面 + 歌名/作者 + 进度 + 控件
    private func leftColumn(width: CGFloat, coverSide: CGFloat, compact: Bool) -> some View {
        VStack(spacing: compact ? 4 : 8) {
            landscapeCover(side: min(width - 8, coverSide))
                .onTapGesture { toggleLyrics() }

            if compact {
                trackInfoCompact
            } else {
                trackInfo
            }

            progress

            if compact {
                controlsCompact
            } else {
                controls
            }
        }
    }

    // MARK: - 宽屏（iPad / 折叠屏展开）

    private func wideLayout(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 32) {
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                landscapeCover(side: min(width * 0.28, height * 0.62))
                trackInfo
                Spacer(minLength: 0)
            }
            .frame(maxWidth: width * 0.38)

            VStack(spacing: 18) {
                ViewThatFits(in: .vertical) {
                    lyricsPage
                    trackInfo
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                progress
                controls
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 16)
    }

    // MARK: - 横屏紧凑组件

    private var trackInfoCompact: some View {
        VStack(spacing: 3) {
            Text(playerService.currentMusic?.title ?? "未知歌曲")
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)

            Text(playerService.currentMusic?.artist ?? "未知歌手")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var controlsCompact: some View {
        HStack(spacing: 26) {
            Button {
                playerService.togglePlayMode()
            } label: {
                Image(systemName: playerService.playMode.icon)
                    .font(.subheadline)
            }
            .accessibilityLabel(playerService.playMode.displayName)

            Button {
                playerService.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
            }
            .accessibilityLabel("上一首")

            Button {
                playerService.togglePlayPause()
            } label: {
                Image(systemName: playerService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 46))
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel(playerService.isPlaying ? "暂停" : "播放")

            Button {
                playerService.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .accessibilityLabel("下一首")

            Button {
                playerService.toggleFavorite()
            } label: {
                Image(systemName: playerService.isFavorite ? "heart.fill" : "heart")
                    .font(.subheadline)
                    .foregroundStyle(playerService.isFavorite ? Color.accentColor : Color.white)
            }
            .accessibilityLabel(playerService.isFavorite ? "取消收藏" : "收藏")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.top, 4)
    }

    /// 横屏专用封面：固定尺寸，不带宽高自适应 Spacer
    @ViewBuilder
    private func landscapeCover(side: CGFloat) -> some View {
        if let music = playerService.currentMusic {
            RemoteImage(
                url: APIConfig.buildMusicCoverURL(musicId: music.id, coverFilePath: music.coverFilePath)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color(.secondarySystemFill))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemFill))
                .frame(width: side, height: side)
        }
    }

    // MARK: - 两页

    private var coverPage: some View {
        artwork
            .onTapGesture { toggleLyrics() }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("轻点显示歌词")
    }

    private var lyricsPage: some View {
        LyricsContentView(
            lyrics: playerService.currentLyrics,
            currentPosition: playerService.currentPosition,
            fontSize: appearance.lyricFontSize
        )
    }

    // MARK: - 歌词切换

    private func close() {
        isPresented = false
    }

    private func toggleLyrics() {
        let target: CGFloat = lyricProgress > 0.5 ? 0 : 1
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            lyricProgress = target
        }
    }

    /// 左滑进歌词、右滑回封面；拖动时实时跟随，松手按位移决定
    private func pageDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if !isDraggingPage {
                    isDraggingPage = true
                    dragStartProgress = lyricProgress
                }
                let delta = -value.translation.width / width
                lyricProgress = min(1, max(0, dragStartProgress + delta))
            }
            .onEnded { value in
                defer { isDraggingPage = false }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                let projected = dragStartProgress - value.predictedEndTranslation.width / width
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                    lyricProgress = projected > 0.5 ? 1 : 0
                }
            }
    }

    // MARK: - 封面模糊背景

    @ViewBuilder
    private var coverBackground: some View {
        if let music = playerService.currentMusic {
            RemoteImage(
                url: APIConfig.buildMusicCoverURL(musicId: music.id, coverFilePath: music.coverFilePath)
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Color(.systemBackground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(1.35)
            .blur(radius: 55)
            .overlay(Color.black.opacity(0.52))
            .clipped()
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.35), value: music.id)
        } else {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
    }

    // MARK: - 封面

    @ViewBuilder
    private var artwork: some View {
        Spacer(minLength: 8)

        if let music = playerService.currentMusic {
            RemoteImage(
                url: APIConfig.buildMusicCoverURL(musicId: music.id, coverFilePath: music.coverFilePath)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color(.secondarySystemFill))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 280, height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        }

        Spacer(minLength: 8)
    }

    // MARK: - 曲目信息

    private var trackInfo: some View {
        VStack(spacing: 6) {
            Text(playerService.currentMusic?.title ?? "未知歌曲")
                .font(.title2)
                .fontWeight(.bold)
                .lineLimit(1)

            Text(playerService.currentMusic?.artist ?? "未知歌手")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .overlay(alignment: .trailing) {
            if !isWideLayout {
                Button {
                    showSharePanel = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 19))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .disabled(playerService.currentMusic == nil)
                .accessibilityLabel("分享")
            }
        }
    }

    // MARK: - 进度

    private var progress: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { playerService.currentPosition },
                    set: { playerService.seekTo(position: $0) }
                ),
                in: 0...max(playerService.duration, 1)
            )
            .tint(.white)

            HStack {
                Text(formatTime(playerService.currentPosition))
                Spacer()
                Text(formatTime(playerService.duration))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.top, 12)
    }

    // MARK: - 控制

    private var controls: some View {
        HStack(spacing: 36) {
            Button {
                playerService.togglePlayMode()
            } label: {
                Image(systemName: playerService.playMode.icon)
                    .font(.title3)
            }
            .accessibilityLabel(playerService.playMode.displayName)

            Button {
                playerService.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
            }
            .accessibilityLabel("上一首")

            Button {
                playerService.togglePlayPause()
            } label: {
                Image(systemName: playerService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel(playerService.isPlaying ? "暂停" : "播放")

            Button {
                playerService.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
            }
            .accessibilityLabel("下一首")

            Button {
                playerService.toggleFavorite()
            } label: {
                Image(systemName: playerService.isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(playerService.isFavorite ? Color.accentColor : Color.white)
            }
            .accessibilityLabel(playerService.isFavorite ? "取消收藏" : "收藏")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.top, 28)
    }

    // MARK: - 侧滑返回

    private var edgeSwipeArea: some View {
        Color.clear
            .frame(width: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        if value.translation.width > 60 {
                            close()
                        }
                    }
            )
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%d:%02d", min, sec)
    }
}

// MARK: - 歌词

struct LyricsContentView: View {
    let lyrics: String
    let currentPosition: TimeInterval
    var fontSize: Double = 19

    private var parsedLyrics: [(time: TimeInterval, text: String)] {
        LyricsParser.parse(lyrics)
    }

    private var currentIndex: Int {
        LyricsParser.index(at: currentPosition, in: parsedLyrics)
    }

    var body: some View {
        if lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyStateView(title: "暂无歌词", systemImage: "text.bubble")
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 18) {
                        ForEach(Array(parsedLyrics.enumerated()), id: \.offset) { index, line in
                            let isCurrent = index == currentIndex
                            Text(line.text)
                                .font(.system(size: fontSize, weight: .regular))
                                .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.38))
                                .shadow(color: .black.opacity(0.5), radius: 8, y: 1)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .id(index)
                                .animation(.easeInOut(duration: 0.25), value: isCurrent)
                        }
                    }
                    .padding(.vertical, 140)
                }
                .modifier(NoTopScrollEdgeEffect())
                .onAppear {
                    scrollToCurrent(proxy, animated: false)
                }
                .onChange(of: currentIndex) { _ in
                    scrollToCurrent(proxy, animated: true)
                }
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        let index = currentIndex
        guard index >= 0, index < parsedLyrics.count else { return }

        if animated {
            withAnimation(.easeInOut(duration: 0.4)) {
                proxy.scrollTo(index, anchor: .center)
            }
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
    }
}


/// iOS 26 的滚动边缘效果会在内容滚到导航栏下方时给 bar 加背景，
/// 播放页是全屏模糊背景，这里关掉顶部效果避免出现色块。
private struct NoTopScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(nil, for: .top)
        } else {
            content
        }
    }
}


/// 震动手感面板：预设一键切换，也能逐项细调，所有改动即时生效并持久化。
struct HapticsTuningView: View {
    @ObservedObject var haptics: HapticsService
    @Environment(\.dismiss) private var dismiss

    private let builtins = ["柔和", "标准", "强烈", "超强"]
    private let slotNames = ["预设一", "预设二", "预设三", "预设四"]

    private var currentName: String {
        let t = haptics.tuning
        if t == .soft { return "柔和" }
        if t == .standard { return "标准" }
        if t == .intense { return "强烈" }
        if t == .extreme { return "超强" }
        for (index, name) in slotNames.enumerated() {
            if haptics.customPreset(slot: index + 1) == t { return name }
        }
        return "自定义"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("预设") {
                    ForEach(builtins, id: \.self) { name in
                        row(title: name, selected: currentName == name) {
                            haptics.tuning = .preset(named: name)
                        }
                    }
                    ForEach(0..<4, id: \.self) { index in
                        if let saved = haptics.customPreset(slot: index + 1) {
                            row(title: slotNames[index], selected: currentName == slotNames[index]) {
                                haptics.tuning = saved
                            }
                        }
                    }
                    Text("《\(haptics.currentTitle.isEmpty ? "当前歌曲" : haptics.currentTitle)》识别到 \(haptics.onsetCount) 个重音点")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("我的预设") {
                    ForEach(0..<4, id: \.self) { index in
                        HStack {
                            Text(slotNames[index])
                            Spacer()
                            if haptics.customPreset(slot: index + 1) != nil {
                                Button("删除") { haptics.deleteCustom(slot: index + 1) }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                            }
                            Button(haptics.customPreset(slot: index + 1) == nil ? "存为" : "覆盖") {
                                haptics.saveCustom(slot: index + 1)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Text("调好手感后点「存为」，之后在预设里直接选。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("细调") {
                    slider(title: "灵敏度", value: Binding(
                        get: { haptics.tuning.sensitivity },
                        set: { haptics.tuning.sensitivity = $0 }
                    ), range: 0.6...3.0, hint: "越大越挑，只留最重的点")

                    slider(title: "最小间隔", value: Binding(
                        get: { haptics.tuning.minGap },
                        set: { haptics.tuning.minGap = $0 }
                    ), range: 0.05...0.30, hint: "间隔太小会糊成一片")

                    slider(title: "强度", value: Binding(
                        get: { haptics.tuning.strength },
                        set: { haptics.tuning.strength = $0 }
                    ), range: 0.5...2.0, hint: "每次重击的力度")

                    slider(title: "锐度", value: Binding(
                        get: { haptics.tuning.sharpness },
                        set: { haptics.tuning.sharpness = $0 }
                    ), range: 0.4...1.0, hint: "越高越脆，越低越闷")

                    slider(title: "打底强度", value: Binding(
                        get: { haptics.tuning.floor },
                        set: { haptics.tuning.floor = $0 }
                    ), range: 0...0.6, hint: "安静段落的基础震动，越高越顶")

                    slider(title: "连续铺底", value: Binding(
                        get: { haptics.tuning.bed },
                        set: { haptics.tuning.bed = $0 }
                    ), range: 0...1.0, hint: "0 为纯打击，越大越有持续的推背感")
                }

                Section {
                    Button("试一下震动") { haptics.playTest() }
                    Button("恢复默认") { haptics.tuning = .appDefault }
                }
            }
            .navigationTitle("震动手感")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func row(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    private func slider(title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
