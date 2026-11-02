import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject var playerService: AudioPlayerService
    @Binding var showNowPlaying: Bool

    private var progress: Double {
        guard playerService.duration > 0 else { return 0 }
        return min(max(playerService.currentPosition / playerService.duration, 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            if let music = playerService.currentMusic {
                CoverImage(
                    url: APIConfig.buildMusicCoverURL(musicId: music.id, coverFilePath: music.coverFilePath),
                    size: Layout.miniCoverSize,
                    cornerRadius: 8
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playerService.currentMusic?.title ?? "")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(playerService.currentMusic?.artist ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                playerService.togglePlayPause()
            } label: {
                Image(systemName: playerService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerService.isPlaying ? "暂停" : "播放")

            Button {
                playerService.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下一首")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(Capsule())
        .overlay(alignment: .bottom) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .padding(.horizontal, 20)
                .padding(.bottom, 1)
        }
        .contentShape(Capsule())
        .onTapGesture {
            showNowPlaying = true
        }
    }
}

/// iOS 26 的 tabViewBottomAccessory 专用（系统负责位置与玻璃外观）
struct MiniPlayerAccessory: View {
    @EnvironmentObject var playerService: AudioPlayerService
    @Binding var showNowPlaying: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                if let music = playerService.currentMusic {
                    CoverImage(
                        url: APIConfig.buildMusicCoverURL(musicId: music.id, coverFilePath: music.coverFilePath),
                        size: 40,
                        cornerRadius: 10
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(playerService.currentMusic?.title ?? "")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(playerService.currentMusic?.artist ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Button {
                    playerService.togglePlayPause()
                } label: {
                    Image(systemName: playerService.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)

                Button {
                    playerService.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(height: 3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            showNowPlaying = true
        }
    }

    private var progress: Double {
        guard playerService.duration > 0 else { return 0 }
        return min(max(playerService.currentPosition / playerService.duration, 0), 1)
    }
}
