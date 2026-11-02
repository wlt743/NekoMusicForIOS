import ActivityKit
import SwiftUI
import WidgetKit

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricActivityAttributes.self) { context in
            LockScreenLyrics(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .font(.title3)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        Text(context.state.current)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.next)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(context.state.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Text(context.state.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 70)
            } minimal: {
                Image(systemName: "music.note")
            }
            .keylineTint(.pink)
        }
    }
}

/// 锁屏卡片：左侧封面 + 右侧三行歌词，当前行高亮
struct LockScreenLyrics: View {
    let context: ActivityViewContext<LyricActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(context.state.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(context.state.artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.previous.isEmpty ? " " : context.state.previous)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(context.state.current.isEmpty ? " " : context.state.current)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    Text(context.state.next.isEmpty ? " " : context.state.next)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = context.state.artworkData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(0.14))
                .frame(width: 58, height: 58)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
        }
    }
}
