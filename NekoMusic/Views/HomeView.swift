import SwiftUI

struct HomeView: View {
    @EnvironmentObject var playerService: AudioPlayerService
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appearance: AppearanceSettings

    @State private var dailyMusic: [Music] = []
    @State private var rankingMusic: [Music] = []
    @State private var latestMusic: [Music] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载中…")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    EmptyStateView(
                        title: "加载失败",
                        systemImage: "wifi.exclamationmark",
                        description: error,
                        actionTitle: "重试"
                    ) {
                        Task { await loadData() }
                    }
                } else {
                    content
                }
            }
            .navigationTitle("NekoMusic")
            .toolbarBackground(.hidden, for: .navigationBar)
            .refreshable { await loadData() }
            .task {
                if rankingMusic.isEmpty && latestMusic.isEmpty {
                    await loadData()
                }
            }
            .onChange(of: authService.isLoggedIn) { _ in
                Task { await loadData() }
            }
        }
    }

    private var content: some View {
        List {
            if !dailyMusic.isEmpty {
                Section {
                    ForEach(dailyMusic.prefix(6)) { music in
                        Button {
                            play(dailyMusic, music)
                        } label: {
                            MusicRow(
                                music: music,
                                isCurrent: playerService.currentMusic?.id == music.id,
                                isPlaying: playerService.isPlaying
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    sectionHeader(
                        "每日推荐",
                        systemImage: "sparkles",
                        destination: MusicListView(title: "每日推荐", musics: dailyMusic)
                    )
                }
            }

            if !rankingMusic.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(rankingMusic.prefix(8)) { music in
                                Button {
                                    play(rankingMusic, music)
                                } label: {
                                    MusicCard(music: music)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: Layout.horizontalPadding, bottom: 0, trailing: Layout.horizontalPadding))
                    .listRowBackground(Color.clear)
                } header: {
                    sectionHeader(
                        "热门排行",
                        systemImage: "flame",
                        destination: MusicListView(title: "热门排行", musics: rankingMusic)
                    )
                }
            }

            if !latestMusic.isEmpty {
                Section {
                    ForEach(latestMusic.prefix(10)) { music in
                        Button {
                            play(latestMusic, music)
                        } label: {
                            MusicRow(
                                music: music,
                                isCurrent: playerService.currentMusic?.id == music.id,
                                isPlaying: playerService.isPlaying
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    sectionHeader(
                        "最新上架",
                        systemImage: "music.note",
                        destination: MusicListView(title: "最新上架", musics: latestMusic)
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
            .background { WallpaperBackdrop() }
    }

    private func sectionHeader(_ title: String, systemImage: String, destination: some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            SectionHeader(title: title, systemImage: systemImage)
            Spacer()
            NavigationLink("更多", destination: destination)
                .font(.subheadline)
        }
    }

    private func play(_ list: [Music], _ music: Music) {
        let index = list.firstIndex(of: music) ?? 0
        playerService.setPlaylist(list, startAt: index)
    }

    private func loadData() async {
        if rankingMusic.isEmpty && latestMusic.isEmpty {
            isLoading = true
        }
        errorMessage = nil

        do {
            async let ranking = MusicService.shared.getRanking()
            async let latest = MusicService.shared.getLatest()
            async let daily = Self.fetchDailyRecommendations(token: authService.token)

            let (rankingResult, latestResult, dailyResult) = try await (ranking, latest, daily)

            await MainActor.run {
                self.rankingMusic = BlacklistService.shared.filter(rankingResult)
                self.latestMusic = BlacklistService.shared.filter(latestResult)
                self.dailyMusic = BlacklistService.shared.filter(dailyResult)
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    /// 每日推荐失败不影响首页其它区块
    private static func fetchDailyRecommendations(token: String?) async -> [Music] {
        guard let token = token, !token.isEmpty else { return [] }
        return (try? await MusicService.shared.getDailyRecommendations(token: token)) ?? []
    }
}

// MARK: - 横向卡片

struct MusicCard: View {
    let music: Music

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(
                url: APIConfig.buildMusicCoverURL(musicId: music.id, coverFilePath: music.coverFilePath),
                size: 140,
                cornerRadius: Layout.cardRadius
            )

            Text(music.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)

            Text(music.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 140, alignment: .leading)
    }
}
