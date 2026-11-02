import SwiftUI

struct MusicListView: View {
    @EnvironmentObject var playerService: AudioPlayerService

    let title: String
    let musics: [Music]

    var body: some View {
        List {
            Section {
                Button {
                    playerService.setPlaylist(musics)
                } label: {
                    Label("播放全部（\(musics.count)）", systemImage: "play.fill")
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
