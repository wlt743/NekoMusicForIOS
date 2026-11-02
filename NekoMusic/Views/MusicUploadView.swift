import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

struct MusicUploadView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var tags = ""
    @State private var language = "中文"
    @State private var durationText = ""

    @State private var audioFile: PickedFile?
    @State private var lyricsFile: PickedFile?
    @State private var coverItem: PhotosPickerItem?
    @State private var coverData: Data?

    @State private var showAudioImporter = false
    @State private var showLyricsImporter = false
    @State private var isUploading = false
    @State private var message = ""
    @State private var showMessage = false
    @State private var succeeded = false

    private let languages = ["中文", "粤语", "上海语", "英文", "日语", "韩语", "法语", "德语", "俄语", "纯音乐"]

    private var canSubmit: Bool {
        !isUploading && audioFile != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !artist.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("歌曲标题", text: $title)
                    TextField("歌手", text: $artist)
                    Picker("语言", selection: $language) {
                        ForEach(languages, id: \.self) { item in
                            Text(item).tag(item)
                        }
                    }
                    TextField("专辑（可选）", text: $album)
                    TextField("标签，逗号分隔（可选）", text: $tags)
                    TextField("时长（秒）", text: $durationText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("歌曲信息")
                } footer: {
                    Text("标题、歌手、语言为必填；时长选择音频后会自动识别。")
                }

                Section {
                    Button {
                        showAudioImporter = true
                    } label: {
                        HStack {
                            Label("选择音频文件", systemImage: "waveform")
                            Spacer()
                            if let audioFile = audioFile {
                                Text(audioFile.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    PhotosPicker(selection: $coverItem, matching: .images) {
                        HStack {
                            Label("选择封面（可选）", systemImage: "photo")
                            Spacer()
                            if coverData != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .onChange(of: coverItem) { item in
                        guard let item = item else { return }
                        Task { await loadCover(item) }
                    }

                    Button {
                        showLyricsImporter = true
                    } label: {
                        HStack {
                            Label("选择歌词 .lrc（可选）", systemImage: "text.alignleft")
                            Spacer()
                            if let lyricsFile = lyricsFile {
                                Text(lyricsFile.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("文件")
                } footer: {
                    Text("音频支持 MP3 / FLAC / WAV。上传后进入审核，结果会以站内消息通知。")
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isUploading {
                                ProgressView()
                            } else {
                                Text("上传")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSubmit)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("上传音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: audioTypes) { result in
                handleAudioPick(result)
            }
            .fileImporter(isPresented: $showLyricsImporter, allowedContentTypes: lyricsTypes) { result in
                handleLyricsPick(result)
            }
            .alert(succeeded ? "上传成功" : "提示", isPresented: $showMessage) {
                if succeeded {
                    Button("好") { dismiss() }
                } else {
                    Button("确定") {}
                }
            } message: {
                Text(message)
            }
        }
    }

    // MARK: - 类型

    private var audioTypes: [UTType] {
        ["mp3", "flac", "wav"].compactMap { UTType(filenameExtension: $0) }
    }

    private var lyricsTypes: [UTType] {
        [UTType(filenameExtension: "lrc"), .plainText].compactMap { $0 }
    }

    // MARK: - 选择文件

    private func handleAudioPick(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result {
                message = error.localizedDescription
                showMessage = true
            }
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            message = "无法读取所选音频"
            showMessage = true
            return
        }

        let ext = url.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "mp3": mime = "audio/mpeg"
        case "flac": mime = "audio/flac"
        default: mime = "audio/wav"
        }

        guard ["mp3", "flac", "wav"].contains(ext) else {
            message = "只支持 MP3 / FLAC / WAV"
            showMessage = true
            return
        }

        audioFile = PickedFile(name: url.lastPathComponent, mimeType: mime, data: data)

        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            title = url.deletingPathExtension().lastPathComponent
        }

        Task {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite, seconds > 0 {
                    durationText = String(Int(seconds.rounded()))
                }
            }
        }
    }

    private func handleLyricsPick(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            message = "无法读取歌词文件"
            showMessage = true
            return
        }
        lyricsFile = PickedFile(name: url.lastPathComponent, mimeType: "text/plain", data: data)
    }

    private func loadCover(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = prepareCoverData(image) else {
            return
        }
        coverData = jpeg
    }

    private func prepareCoverData(_ image: UIImage, maxSide: CGFloat = 800) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }

    // MARK: - 提交

    private func submit() async {
        guard let token = authService.token, let userId = authService.currentUser?.id else {
            message = "请先登录"
            showMessage = true
            return
        }
        guard let audio = audioFile else {
            message = "请选择音频文件"
            showMessage = true
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedArtist.isEmpty else {
            message = "标题和歌手不能为空"
            showMessage = true
            return
        }

        guard let duration = Int(durationText), duration > 0 else {
            message = "请填写有效的时长（秒）"
            showMessage = true
            return
        }

        isUploading = true
        defer { isUploading = false }

        do {
            let response = try await MusicUploadService.shared.upload(
                title: trimmedTitle,
                artist: trimmedArtist,
                language: language,
                album: album.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: tags.trimmingCharacters(in: .whitespacesAndNewlines),
                duration: duration,
                uploadUserId: userId,
                music: MusicUploadService.FilePayload(
                    filename: audio.name,
                    mimeType: audio.mimeType,
                    data: audio.data
                ),
                cover: coverData.map {
                    MusicUploadService.FilePayload(filename: "cover.jpg", mimeType: "image/jpeg", data: $0)
                },
                lyrics: lyricsFile.map {
                    MusicUploadService.FilePayload(filename: $0.name, mimeType: "text/plain", data: $0.data)
                },
                token: token
            )

            succeeded = response.success
            message = response.message ?? (response.success ? "上传成功，等待审核" : "上传失败")
            showMessage = true
        } catch {
            message = error.localizedDescription
            showMessage = true
        }
    }
}

private struct PickedFile {
    let name: String
    let mimeType: String
    let data: Data
}
