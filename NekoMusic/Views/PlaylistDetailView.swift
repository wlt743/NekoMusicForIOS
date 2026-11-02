import SwiftUI

struct PlaylistDetailView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var playerService: AudioPlayerService

    let playlistId: Int
    let playlistName: String

    @State private var detail: PlaylistInfo?
    @State private var musics: [Music] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isFavorite = false
    @State private var favoriteLoaded = false
    @State private var showEdit = false
    @State private var actionMessage = ""
    @State private var showActionMessage = false

    private var displayName: String {
        detail?.name ?? playlistName
    }

    private var coverURL: String? {
        if let cover = detail?.coverPath, !cover.isEmpty {
            return APIConfig.buildFullURL(path: cover)
        }
        if let cover = detail?.firstMusicCover, !cover.isEmpty {
            return APIConfig.buildFullURL(path: cover)
        }
        if let first = musics.first {
            return APIConfig.buildMusicCoverURL(musicId: first.id, coverFilePath: first.coverFilePath)
        }
        return nil
    }

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
                    Task { await loadPlaylistMusic() }
                }
            } else if musics.isEmpty {
                EmptyStateView(
                    title: "歌单暂无音乐",
                    systemImage: "music.note",
                    description: detail?.description
                )
            } else {
                List {
                    Section {
                        header
                            .listRowInsets(EdgeInsets(top: 8, leading: Layout.horizontalPadding, bottom: 8, trailing: Layout.horizontalPadding))
                            .listRowBackground(Color.clear)

                        Button {
                            playerService.setPlaylist(musics)
                        } label: {
                            Label("播放全部（\(musics.count) 首）", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .listRowInsets(EdgeInsets(top: 4, leading: Layout.horizontalPadding, bottom: 8, trailing: Layout.horizontalPadding))
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
        .navigationTitle(displayName)
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

            if isOwnPlaylist {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showEdit = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("编辑歌单")
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            PlaylistEditSheet(
                playlistId: playlistId,
                initialName: displayName,
                initialDescription: detail?.description ?? ""
            ) {
                Task { await loadPlaylistMusic() }
            }
        }
        .alert("提示", isPresented: $showActionMessage) {
            Button("确定") {}
        } message: {
            Text(actionMessage)
        }
        .refreshable {
            await loadPlaylistMusic()
        }
        .task {
            if musics.isEmpty {
                await loadPlaylistMusic()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(url: coverURL, size: 88, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 6) {
                Text(displayName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)

                if let username = detail?.username, !username.isEmpty {
                    Text(username)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("\(musics.count) 首")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let description = detail?.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var isOwnPlaylist: Bool {
        guard let detail = detail, let me = authService.currentUser?.id else { return false }
        return detail.userId == me
    }

    private func toggleFavorite() async {
        guard let token = authService.token else {
            actionMessage = "请先登录"
            showActionMessage = true
            return
        }
        do {
            if isFavorite {
                try await FavoritePlaylistService.shared.remove(playlistId: playlistId, token: token)
                isFavorite = false
            } else {
                try await FavoritePlaylistService.shared.add(playlistId: playlistId, token: token)
                isFavorite = true
            }
        } catch {
            actionMessage = error.localizedDescription
            showActionMessage = true
        }
    }

    private func loadPlaylistMusic() async {
        isLoading = true
        errorMessage = nil

        // 1. 公开歌单详情（/api/playlist/{id}），失败不阻断曲目列表
        if let response: PlaylistResponse = try? await NetworkService.shared.get(
            url: APIConfig.playlistDetailURL(id: playlistId)
        ) {
            await MainActor.run {
                self.detail = response.playlist
            }
        }

        // 2. 是否已收藏（登录才查）
        if !favoriteLoaded, let token = authService.token {
            isFavorite = await FavoritePlaylistService.shared.isFavorite(playlistId: playlistId, token: token)
            favoriteLoaded = true
        }

        // 3. 曲目列表
        do {
            let response: PlaylistMusicListResponse = try await NetworkService.shared.get(
                url: APIConfig.playlistMusicURL(id: playlistId),
                token: authService.token
            )

            if response.success, let musicList = response.musicList {
                let converted = musicList.map { pm in
                    Music(
                        id: pm.id,
                        title: pm.title,
                        artist: pm.artist,
                        album: pm.album,
                        duration: pm.duration,
                        filePath: pm.filePath,
                        coverFilePath: pm.coverPath,
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
            } else {
                await MainActor.run {
                    self.errorMessage = response.message
                    self.isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}


// MARK: - 歌单编辑

struct PlaylistEditSheet: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    let playlistId: Int
    let initialName: String
    let initialDescription: String
    var onSaved: () -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var message = ""
    @State private var showMessage = false
    @State private var succeeded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("歌单名称", text: $name)
                    TextField("描述（可选）", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text("名称最多 255 字，描述最多 500 字。")
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("保存").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isSaving)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("编辑歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                if name.isEmpty {
                    name = initialName
                    description = initialDescription
                }
            }
            .alert(succeeded ? "已保存" : "提示", isPresented: $showMessage) {
                if succeeded {
                    Button("好") {
                        onSaved()
                        dismiss()
                    }
                } else {
                    Button("确定") {}
                }
            } message: {
                Text(message)
            }
        }
    }

    private func save() async {
        guard let token = authService.token else {
            message = "请先登录"
            showMessage = true
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "歌单名称不能为空"
            showMessage = true
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await PlaylistEditService.shared.update(
                playlistId: playlistId,
                name: trimmed,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                token: token
            )
            succeeded = true
            message = "歌单已更新"
            showMessage = true
        } catch {
            message = error.localizedDescription
            showMessage = true
        }
    }
}
