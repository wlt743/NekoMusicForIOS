import SwiftUI

/// 收藏的歌单列表
struct FavoritePlaylistsView: View {
    @EnvironmentObject var authService: AuthService

    @State private var playlists: [FavoritePlaylist] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                EmptyStateView(
                    title: "加载失败",
                    systemImage: "bookmark.slash",
                    description: error,
                    actionTitle: "重试"
                ) {
                    Task { await load() }
                }
            } else if playlists.isEmpty {
                EmptyStateView(
                    title: "还没有收藏歌单",
                    systemImage: "bookmark",
                    description: "在歌单详情页点收藏，就会出现在这里"
                )
            } else {
                List {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            FavoritePlaylistDetailView(playlist: playlist)
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(.secondarySystemFill))
                                    .frame(width: Layout.coverSize, height: Layout.coverSize)
                                    .overlay {
                                        Image(systemName: "music.note.list")
                                            .foregroundStyle(.secondary)
                                    }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .lineLimit(1)
                                    Text("\(playlist.musicCount) 首 · \(playlist.creator?.nickname ?? "未知")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("收藏歌单")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if playlists.isEmpty {
                await load()
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let token = authService.token else {
            isLoading = false
            return
        }
        do {
            let result = try await FavoritePlaylistService.shared.list(token: token)
            await MainActor.run {
                self.playlists = result
                self.isLoading = false
                self.errorMessage = nil
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

/// 收藏歌单里的曲目（只能对已收藏的歌单用这个接口）
struct FavoritePlaylistDetailView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var playerService: AudioPlayerService

    let playlist: FavoritePlaylist

    @State private var musics: [Music] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isFavorite = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                EmptyStateView(
                    title: "加载失败",
                    systemImage: "exclamationmark.triangle",
                    description: error,
                    actionTitle: "重试"
                ) {
                    Task { await load() }
                }
            } else if musics.isEmpty {
                EmptyStateView(title: "歌单暂无音乐", systemImage: "music.note")
            } else {
                List {
                    Section {
                        Button {
                            playerService.setPlaylist(musics)
                        } label: {
                            Label("播放全部（\(musics.count) 首）", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .listRowInsets(EdgeInsets(top: 8, leading: Layout.horizontalPadding, bottom: 8, trailing: Layout.horizontalPadding))
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        ForEach(Array(musics.enumerated()), id: \.element.id) { index, music in
                            Button {
                                playerService.setPlaylist(musics, startAt: index)
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
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Image(systemName: isFavorite ? "bookmark.fill" : "bookmark")
                }
                .accessibilityLabel(isFavorite ? "取消收藏歌单" : "收藏歌单")
            }
        }
        .task {
            if musics.isEmpty {
                await load()
            }
        }
    }

    private func load() async {
        guard let token = authService.token else {
            isLoading = false
            return
        }
        do {
            let result = try await FavoritePlaylistService.shared.music(playlistId: playlist.id, token: token)
            let converted = result.map { item in
                Music(
                    id: item.id,
                    title: item.title,
                    artist: item.artist,
                    album: item.album ?? "",
                    duration: item.duration ?? 0,
                    filePath: item.filename,
                    coverFilePath: nil,
                    uploadUserId: nil,
                    createdAt: nil,
                    playCount: nil,
                    lrc: nil
                )
            }
            await MainActor.run {
                self.musics = BlacklistService.shared.filter(converted)
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func toggleFavorite() async {
        guard let token = authService.token else { return }
        do {
            if isFavorite {
                try await FavoritePlaylistService.shared.remove(playlistId: playlist.id, token: token)
                await MainActor.run { self.isFavorite = false }
            } else {
                try await FavoritePlaylistService.shared.add(playlistId: playlist.id, token: token)
                await MainActor.run { self.isFavorite = true }
            }
        } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription }
        }
    }
}
