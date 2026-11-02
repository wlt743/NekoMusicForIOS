import SwiftUI

/// 听歌识曲
struct RecognizeView: View {
    @StateObject private var service = RecognizeService.shared
    @EnvironmentObject var playerService: AudioPlayerService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            stateSection

            Spacer()

            actionSection
                .padding(.bottom, 40)
        }
        .padding(.horizontal, 24)
        .navigationTitle("听歌识曲")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if service.isRecording {
                service.cancel()
            }
        }
    }

    // MARK: - 状态区

    @ViewBuilder
    private var stateSection: some View {
        if service.isRecording {
            VStack(spacing: 18) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(.tint)

                Text(String(format: "%.1f s", service.elapsed))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                Text("正在听… 保持安静，让手机靠近音源")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if service.isRecognizing {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("正在识别…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let track = service.matched {
            resultCard(track)
        } else if let notice = service.notice {
            VStack(spacing: 12) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text(notice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else if let error = service.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 88))
                    .foregroundStyle(.secondary)
                Text("点击下方按钮，录一小段音乐")
                    .foregroundStyle(.secondary)
                Text("建议录制 5–15 秒，安静环境下识别率更高")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func resultCard(_ track: RecognizedTrack) -> some View {
        VStack(spacing: 16) {
            CoverImage(
                url: APIConfig.buildMusicCoverURL(musicId: track.id, coverFilePath: nil),
                size: 180
            )

            VStack(spacing: 6) {
                Text(track.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !track.album.isEmpty {
                    Text(track.album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(String(format: "置信度 %.0f%%", track.confidence * 100))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                playerService.setPlaylist([track.asMusic], startAt: 0)
                dismiss()
            } label: {
                Label("播放这首", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
        }
    }

    // MARK: - 操作区

    @ViewBuilder
    private var actionSection: some View {
        if service.isRecording {
            Button {
                Task { await service.stopAndRecognize() }
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("停止并识别")
        } else if service.isRecognizing {
            EmptyView()
        } else {
            Button {
                Task { try? await service.start() }
            } label: {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)
            }
            .accessibilityLabel("开始录音")
        }
    }
}
