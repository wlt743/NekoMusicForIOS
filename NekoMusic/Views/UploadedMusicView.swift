import SwiftUI

/// 我上传的音乐（仅审核通过的）
struct UploadedMusicView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var playerService: AudioPlayerService

    @State private var items: [UploadedMusic] = []
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
                    systemImage: "arrow.up.circle",
                    description: error,
                    actionTitle: "重试"
                ) {
                    Task { await load() }
                }
            } else if items.isEmpty {
                EmptyStateView(
                    title: "还没有通过审核的上传",
                    systemImage: "arrow.up.circle",
                    description: "在音乐库 › 上传音乐 里提交作品，审核通过后会出现在这里"
                )
            } else {
                List {
                    Section {
                        ForEach(items) { item in
                            Button {
                                play(item)
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImage(
                                        url: APIConfig.buildMusicCoverURL(musicId: item.id, coverFilePath: nil),
                                        size: Layout.coverSize
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .lineLimit(1)
                                        Text(item.artist)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            if let language = item.language, !language.isEmpty {
                                                Text(language)
                                            }
                                            if let format = item.fileFormat, !format.isEmpty {
                                                Text(format.uppercased())
                                            }
                                            if let quality = item.maxQuality, !quality.isEmpty {
                                                Text(quality.uppercased())
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    }

                                    Spacer(minLength: 4)

                                    Image(systemName: playerService.currentMusic?.id == item.id
                                          ? (playerService.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                          : "play.circle")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("只显示审核通过的作品。上传后可在「站内消息」里看到审核结果。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("我上传的音乐")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if items.isEmpty {
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
            let result = try await MusicUploadService.shared.uploadedMusic(token: token)
            await MainActor.run {
                self.items = result
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

    private func play(_ item: UploadedMusic) {
        let music = Music(
            id: item.id,
            title: item.title,
            artist: item.artist,
            album: item.album ?? "",
            duration: item.duration ?? 0,
            filePath: nil,
            coverFilePath: nil,
            uploadUserId: nil,
            createdAt: nil,
            playCount: nil,
            lrc: nil
        )
        playerService.setPlaylist([music], startAt: 0)
    }
}
