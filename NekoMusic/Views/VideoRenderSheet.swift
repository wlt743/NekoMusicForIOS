import SwiftUI

/// 分享视频渲染进度
struct VideoRenderSheet: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    let music: Music
    @StateObject private var service = VideoRenderService()
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()

                CoverImage(
                    url: APIConfig.buildMusicCoverURL(musicId: music.id, coverFilePath: music.coverFilePath),
                    size: 140
                )

                VStack(spacing: 6) {
                    Text(music.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(music.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                statusSection

                Spacer()

                if let url = service.videoURL {
                    HStack(spacing: 12) {
                        Button {
                            showShare = true
                        } label: {
                            Label("分享视频", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .sheet(isPresented: $showShare) {
                            ActivityView(items: [url])
                        }

                        ShareLink(item: url) {
                            Label("保存", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .padding(.horizontal, 24)
                } else if service.status == .failed {
                    Button("重试") {
                        Task { await start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Spacer(minLength: 24)
            }
            .navigationTitle("生成分享视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                await start()
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(spacing: 10) {
            if service.status == .processing || service.status == .pending {
                ProgressView()
                    .controlSize(.regular)
            }

            Text(service.status.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if service.status != .idle && service.status != .done {
                Text("非 VIP 版本限 \(service.durationSec) 秒，带平台水印")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let remain = service.remainingToday {
                Text("今天还可生成 \(remain) 次")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let notice = service.notice, service.status == .done {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = service.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
    }

    private func start() async {
        guard let token = authService.token else {
            service.errorMessage = "请先登录"
            return
        }
        await service.create(musicId: music.id, token: token)
    }
}
