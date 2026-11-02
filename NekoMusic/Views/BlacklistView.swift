import SwiftUI

struct BlacklistView: View {
    @EnvironmentObject var playerService: AudioPlayerService
    @StateObject private var blacklist = BlacklistService.shared

    var body: some View {
        Group {
            if blacklist.songs.isEmpty {
                EmptyStateView(
                    title: "黑名单是空的",
                    systemImage: "hand.raised.slash",
                    description: "在播放页对不想再听的歌点「拉黑」"
                )
            } else {
                List {
                    Section {
                        ForEach(blacklist.songs) { song in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .lineLimit(1)
                                if !song.artist.isEmpty {
                                    Text(song.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                blacklist.unblock(blacklist.songs[index].id)
                            }
                        }
                    } footer: {
                        Text("左滑可以移出黑名单。黑名单只保存在本机。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("黑名单")
        .navigationBarTitleDisplayMode(.inline)
    }
}
