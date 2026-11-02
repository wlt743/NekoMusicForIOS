import SwiftUI

enum TargetMode: String, CaseIterable, Identifiable {
    case createNew = "新建歌单"
    case existing = "已有歌单"

    var id: String { rawValue }
}

struct PlaylistImportView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var source: ImportPlatform = .netease
    @State private var input = ""

    @State private var targetMode: TargetMode = .createNew
    @State private var newPlaylistName = ""
    @State private var selectedPlaylistId: Int?
    @State private var myPlaylists: [PlaylistInfo] = []
    @State private var isLoadingPlaylists = false

    @State private var isImporting = false
    @State private var isFinished = false
    @State private var started: ImportStartInfo?
    @State private var tracks: [ImportTrack] = []
    @State private var currentIndex = 0
    @State private var summary: ImportSummary?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var importTask: Task<Void, Never>?

    private var totalTracks: Int {
        started?.total ?? 0
    }

    private var canStart: Bool {
        guard !isImporting, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch targetMode {
        case .createNew:
            return !newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .existing:
            return selectedPlaylistId != nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isImporting || isFinished {
                    progressSection
                }

                if !isImporting && !isFinished {
                    sourceSection
                    inputSection
                    targetSection
                    startSection
                    helpSection
                }
            }
            .navigationTitle("导入外部歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isImporting {
                        Button("取消") {
                            importTask?.cancel()
                            isImporting = false
                        }
                    } else {
                        Button("关闭") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isFinished {
                        Button("完成") {
                            NotificationCenter.default.post(name: .playlistsDidChange, object: nil)
                            dismiss()
                        }
                    }
                }
            }
            .alert("导入失败", isPresented: $showError) {
                Button("确定") {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            .task {
                await loadPlaylistsIfNeeded()
            }
        }
    }

    // MARK: - 配置区

    private var sourceSection: some View {
        Section {
            Picker("来源", selection: $source) {
                ForEach(ImportPlatform.allCases) { platform in
                    Label(platform.title, systemImage: platform.icon)
                        .tag(platform)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("音源")
        } footer: {
            Text(source.hint)
        }
    }

    private var inputSection: some View {
        Section {
            TextField(source.placeholder, text: $input, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            Button {
                if let clipboard = UIPasteboard.general.string {
                    input = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("歌单链接或 ID")
        } footer: {
            Text("匹配与下载全部在服务端完成，导入后曲目顺序与来源歌单一致。")
        }
    }

    private var targetSection: some View {
        Section {
            Picker("导入到", selection: $targetMode) {
                ForEach(TargetMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch targetMode {
            case .createNew:
                TextField("新歌单名称", text: $newPlaylistName)
                    .textInputAutocapitalization(.never)

            case .existing:
                if isLoadingPlaylists {
                    HStack {
                        ProgressView()
                        Text("加载歌单…")
                            .foregroundStyle(.secondary)
                    }
                } else if myPlaylists.isEmpty {
                    Text("还没有可用的歌单，先新建一个吧")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("目标歌单", selection: $selectedPlaylistId) {
                        Text("请选择").tag(Int?.none)
                        ForEach(myPlaylists) { playlist in
                            Text("\(playlist.name)（\(playlist.musicCount) 首）")
                                .tag(Int?.some(playlist.id))
                        }
                    }
                }
            }
        } header: {
            Text("导入目标")
        } footer: {
            switch targetMode {
            case .createNew:
                Text("将新建一个歌单，并把命中的曲目按来源顺序加入。")
            case .existing:
                Text("命中的曲目会追加到所选歌单末尾，已存在的曲目会被跳过。")
            }
        }
    }

    private var startSection: some View {
        Section {
            Button {
                startImport()
            } label: {
                HStack {
                    Spacer()
                    Text("开始导入")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canStart)
            .listRowBackground(Color.clear)
        } footer: {
            if !authService.isLoggedIn {
                Text("导入需要登录账号。")
                    .foregroundStyle(.red)
            }
        }
    }

    private var helpSection: some View {
        Section("使用说明") {
            Label("在对应 App 中打开歌单并分享", systemImage: "1.circle")
            Label("复制分享链接", systemImage: "2.circle")
            Label("粘贴到上方输入框并选择导入目标", systemImage: "3.circle")
            Label("导入完成后会给你的账号发一条站内消息", systemImage: "4.circle")
        }
    }

    // MARK: - 进度区

    @ViewBuilder
    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(isFinished ? "导入完成" : "正在导入…")
                        .font(.headline)
                    Spacer()
                    Text("\(min(currentIndex, totalTracks)) / \(totalTracks)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: Double(min(currentIndex, totalTracks)), total: Double(max(totalTracks, 1)))

                if let summary = summary {
                    HStack(spacing: 12) {
                        statBadge("入库 \(summary.imported)", color: .green)
                        statBadge("已有 \(summary.existed)", color: .blue)
                        statBadge("失败 \(summary.failed)", color: .orange)
                    }
                } else {
                    Text(summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)

            if summary != nil {
                Label("目标歌单已更新，可到「音乐库 › 我的歌单」查看", systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(summary == nil ? "导入进度" : "导入结果")
        }

        if !tracks.isEmpty {
            Section("最近曲目") {
                ForEach(Array(tracks.suffix(6).reversed())) { track in
                    ImportTrackRow(track: track)
                }
            }
        }
    }

    private var summaryLine: String {
        if let title = tracks.last?.title, !title.isEmpty {
            return "正在处理：\(title)"
        }
        return started.map { "来源 \($0.source) · 共 \($0.total) 首" } ?? "正在连接…"
    }

    private func statBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - 动作

    private func loadPlaylistsIfNeeded() async {
        guard authService.isLoggedIn, myPlaylists.isEmpty, let token = authService.token else { return }
        isLoadingPlaylists = true
        defer { isLoadingPlaylists = false }

        if let response: PlaylistListResponse = try? await NetworkService.shared.get(
            url: APIConfig.myPlaylistsURL(),
            token: token
        ) {
            myPlaylists = response.playlists ?? []
            if selectedPlaylistId == nil {
                selectedPlaylistId = myPlaylists.first?.id
            }
        }
    }

    private func startImport() {
        guard let token = authService.token else {
            errorMessage = "请先登录账号再导入"
            showError = true
            return
        }
        guard let resolved = PlaylistImportService.shared.resolveInput(input, platform: source) else {
            errorMessage = "无法解析歌单链接或 ID，请检查输入"
            showError = true
            return
        }

        let targetName = targetMode == .createNew
            ? newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let targetId = targetMode == .existing ? selectedPlaylistId : nil

        isImporting = true
        tracks = []
        currentIndex = 0
        summary = nil
        started = nil

        importTask = Task {
            do {
                let stream = PlaylistImportService.shared.streamImport(
                    platform: source,
                    input: resolved,
                    targetPlaylistId: targetId,
                    targetPlaylistName: targetName,
                    token: token
                )
                for try await event in stream {
                    apply(event)
                }
                await MainActor.run {
                    self.isImporting = false
                    self.isFinished = true
                    if self.summary == nil && self.errorMessage == nil {
                        self.errorMessage = "导入没有返回结果，请检查网络后重试"
                        self.showError = true
                    }
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.isFinished = false
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    @MainActor
    private func apply(_ event: ImportEvent) {
        switch event {
        case .started(let info):
            started = info

        case .track(let track):
            if let index = tracks.firstIndex(where: { $0.index == track.index }) {
                tracks[index] = track
            } else {
                tracks.append(track)
            }
            currentIndex = max(currentIndex, track.index + 1)

        case .progress:
            break

        case .done(let result):
            summary = result
            if result.imported == 0 && result.existed == 0 {
                errorMessage = result.failed > 0
                    ? "没有曲目导入成功（\(result.failed) 首失败）。请确认歌单是公开的，或稍后重试"
                    : "这个歌单没有匹配到任何曲目"
                showError = true
            }
            currentIndex = max(currentIndex, result.total)
            if result.total != 0 {
                started = ImportStartInfo(
                    source: started?.source ?? source.rawValue,
                    total: result.total,
                    targetPlaylistId: started?.targetPlaylistId,
                    targetPlaylistCreated: started?.targetPlaylistCreated ?? false
                )
            }

        case .failure(let message):
            isImporting = false
            isFinished = true
            errorMessage = message
            showError = true
        }
    }
}

// MARK: - 曲目行

private struct ImportTrackRow: View {
    let track: ImportTrack

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: track.status.systemImage)
                .foregroundStyle(track.status.isFailure ? Color.orange : Color.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline)
                    .lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(track.status.label)
                .font(.caption2)
                .foregroundStyle(track.status.isFailure ? Color.orange : Color.secondary)
        }
    }
}

extension Notification.Name {
    /// 歌单内容发生变化（新建 / 导入完成），列表页可监听刷新
    static let playlistsDidChange = Notification.Name("NekoMusic.playlistsDidChange")
}
