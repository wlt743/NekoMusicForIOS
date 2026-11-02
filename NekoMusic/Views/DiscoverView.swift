import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject var playerService: AudioPlayerService

    @State private var searchText = ""
    @State private var searchResults: [Music] = []
    @State private var searchPlaylists: [PlaylistInfo] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    ProgressView("搜索中…")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hasSearched {
                    resultsContent
                } else {
                    EmptyStateView(
                        title: "搜索音乐、歌单",
                        systemImage: "magnifyingglass",
                        description: "输入歌名、歌手或歌单关键词"
                    )
                }
            }
            .background { WallpaperBackdrop() }
            .navigationTitle("发现")
            .searchable(text: $searchText, prompt: "搜索音乐、歌手")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RecognizeView()
                    } label: {
                        Image(systemName: "waveform")
                    }
                    .accessibilityLabel("听歌识曲")
                }
            }
            .submitLabel(.search)
            .onSubmit(of: .search) {
                Task { await performSearch() }
            }
            .onChange(of: searchText) { newValue in
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults = []
                    searchPlaylists = []
                    hasSearched = false
                }
            }
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if searchResults.isEmpty && searchPlaylists.isEmpty {
            EmptyStateView(
                title: "未找到相关内容",
                systemImage: "magnifyingglass",
                description: errorMessage ?? "换个关键词试试"
            )
        } else {
            List {
                if !searchResults.isEmpty {
                    Section("歌曲") {
                        ForEach(searchResults) { music in
                            Button {
                                play(searchResults, music)
                            } label: {
                                MusicRow(
                                    music: music,
                                    isCurrent: playerService.currentMusic?.id == music.id,
                                    isPlaying: playerService.isPlaying
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !searchPlaylists.isEmpty {
                    Section("歌单") {
                        ForEach(searchPlaylists) { playlist in
                            NavigationLink {
                                PlaylistDetailView(playlistId: playlist.id, playlistName: playlist.name)
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImage(
                                        url: APIConfig.buildFullURL(path: playlist.coverPath ?? playlist.firstMusicCover ?? ""),
                                        size: Layout.coverSize
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .lineLimit(1)
                                        Text("\(playlist.musicCount) 首")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listRowBackground(Color(.secondarySystemGroupedBackground).opacity(0.62))
        }
    }

    private func play(_ list: [Music], _ music: Music) {
        let index = list.firstIndex(of: music) ?? 0
        playerService.setPlaylist(list, startAt: index)
    }

    private func performSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        isSearching = true
        hasSearched = true
        errorMessage = nil

        async let songsTask = MusicService.shared.searchMusic(query: query)
        async let playlistsTask: PlaylistListResponse = NetworkService.shared.post(
            url: APIConfig.playlistSearchURL(),
            body: SearchRequest(query: query)
        )

        var songs: [Music] = []
        var playlists: [PlaylistInfo] = []
        var failure: String?

        do {
            songs = try await songsTask
        } catch {
            failure = error.localizedDescription
        }

        do {
            let response = try await playlistsTask
            playlists = response.playlists ?? response.results ?? []
        } catch {
            failure = failure ?? error.localizedDescription
        }

        await MainActor.run {
            self.searchResults = BlacklistService.shared.filter(songs)
            self.searchPlaylists = playlists
            self.errorMessage = failure
            self.isSearching = false
        }
    }
}

// MARK: - 歌单卡片

struct PlaylistCard: View {
    let playlist: PlaylistInfo

    private var coverURL: String {
        APIConfig.buildFullURL(path: playlist.coverPath ?? playlist.firstMusicCover ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: coverURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color(.secondarySystemFill))
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))

            Text(playlist.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)

            Text("\(playlist.musicCount) 首")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
