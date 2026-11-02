import SwiftUI

private struct ReplyTarget: Equatable {
    let id: Int
    let nickname: String
}

struct CommentsView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    let music: Music

    @State private var comments: [MusicComment] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var page = 1
    @State private var hasMore = false
    @State private var totalComments = 0
    @State private var errorMessage: String?
    @State private var inputText = ""
    @State private var replyTarget: ReplyTarget?
    @State private var isSubmitting = false
    @State private var cooldown = 0
    @State private var cooldownTask: Task<Void, Never>?
    @State private var alertMessage = ""
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载评论…")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    EmptyStateView(
                        title: "加载失败",
                        systemImage: "bubble.left.and.exclamationmark.bubble.right",
                        description: error,
                        actionTitle: "重试"
                    ) {
                        Task { await reload() }
                    }
                } else if comments.isEmpty {
                    EmptyStateView(
                        title: "还没有评论",
                        systemImage: "bubble.left",
                        description: "来说第一句吧"
                    )
                } else {
                    list
                }
            }
            .navigationTitle("评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
            .alert("提示", isPresented: $showAlert) {
                Button("确定") {}
            } message: {
                Text(alertMessage)
            }
            .task {
                if comments.isEmpty {
                    await reload()
                }
            }
        }
    }

    // MARK: - 列表

    private var list: some View {
        List {
            Section {
                ForEach(comments) { comment in
                    CommentRow(
                        comment: comment,
                        onReply: {
                            replyTarget = ReplyTarget(id: comment.id, nickname: comment.user.nickname)
                        },
                        onDeleteReply: { reply in
                            Task { await delete(kind: "回复", id: reply.id) }
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if comment.canDelete == true {
                            Button(role: .destructive) {
                                Task { await delete(kind: "评论", id: comment.id) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("共 \(totalComments) 条评论")
            }

            if hasMore {
                Section {
                    Button {
                        Task { await loadPage(page + 1) }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoadingMore {
                                ProgressView()
                            } else {
                                Text("加载更多")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isLoadingMore)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await reload() }
    }

    // MARK: - 输入框

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()

            if let target = replyTarget {
                HStack(spacing: 8) {
                    Text("回复 @\(target.nickname)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        replyTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            HStack(spacing: 10) {
                TextField(replyTarget == nil ? "说点什么…" : "回复 @\(replyTarget!.nickname)", text: $inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else if cooldown > 0 {
                        Text("\(cooldown)s")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18))
                    }
                }
                .disabled(isSubmitting || cooldown > 0 || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    // MARK: - 数据

    private func reload() async {
        page = 1
        hasMore = false
        isLoading = comments.isEmpty
        errorMessage = nil

        do {
            let result = try await CommentService.shared.fetchComments(
                musicId: music.id,
                page: 1,
                token: authService.token
            )
            await MainActor.run {
                self.comments = result.comments
                self.page = result.page
                self.hasMore = result.hasMore
                self.totalComments = result.totalComments
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func loadPage(_ target: Int) async {
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let result = try await CommentService.shared.fetchComments(
                musicId: music.id,
                page: target,
                token: authService.token
            )
            await MainActor.run {
                self.comments.append(contentsOf: result.comments)
                self.page = result.page
                self.hasMore = result.hasMore
                self.totalComments = result.totalComments
            }
        } catch {
            await MainActor.run {
                self.alertMessage = error.localizedDescription
                self.showAlert = true
            }
        }
    }

    private func submit() async {
        guard let token = authService.token else {
            alertMessage = "请先登录后再评论"
            showAlert = true
            return
        }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 500 else {
            alertMessage = "评论最多 500 字"
            showAlert = true
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await CommentService.shared.postComment(
                musicId: music.id,
                content: text,
                parentId: replyTarget?.id,
                token: token
            )
            await MainActor.run {
                self.inputText = ""
                self.replyTarget = nil
            }
            await reload()
            startCooldown()
        } catch {
            let message = Self.friendly(error)
            await MainActor.run {
                self.alertMessage = message
                self.showAlert = true
            }
        }
    }

    /// 后端限制两次发表间隔 5 秒，本地也做同样的冷却
    private func startCooldown() {
        cooldown = 5
        cooldownTask?.cancel()
        cooldownTask = Task {
            while !Task.isCancelled && cooldown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                cooldown -= 1
            }
        }
    }

    private static func friendly(_ error: Error) -> String {
        if case NetworkError.tooManyRequests = error {
            return "发送太频繁了，两次评论至少间隔 5 秒"
        }
        return error.localizedDescription
    }

    private func delete(kind: String, id: Int) async {
        guard let token = authService.token else { return }
        do {
            try await CommentService.shared.deleteComment(id: id, token: token)
            await reload()
        } catch {
            await MainActor.run {
                self.alertMessage = "\(kind)删除失败：\(error.localizedDescription)"
                self.showAlert = true
            }
        }
    }
}

// MARK: - 楼层

private struct CommentRow: View {
    let comment: MusicComment
    let onReply: () -> Void
    let onDeleteReply: (MusicReply) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                avatar(id: comment.user.id, nickname: comment.user.nickname, size: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(comment.user.nickname)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        if let region = comment.ipRegion, !region.isEmpty {
                            Text(region)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 4)

                        Text(NekoDate.format(comment.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(comment.content)
                        .font(.subheadline)
                        .textSelection(.enabled)

                    Button {
                        onReply()
                    } label: {
                        Label("回复", systemImage: "arrowshape.turn.up.left")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let replies = comment.replies, !replies.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(replies) { reply in
                        replyRow(reply)
                    }
                }
                .padding(.leading, 44)
            }
        }
        .padding(.vertical, 4)
    }

    private func replyRow(_ reply: MusicReply) -> some View {
        HStack(alignment: .top, spacing: 8) {
            avatar(id: reply.user.id, nickname: reply.user.nickname, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(reply.user.nickname)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if let target = reply.replyToUser {
                        Text("回复 \(target.nickname)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    if let region = reply.ipRegion, !region.isEmpty {
                        Text(region)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(NekoDate.format(reply.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(reply.content)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .contextMenu {
            if reply.canDelete == true {
                Button(role: .destructive) {
                    onDeleteReply(reply)
                } label: {
                    Label("删除回复", systemImage: "trash")
                }
            }
        }
    }

    private func avatar(id: Int, nickname: String, size: CGFloat) -> some View {
        RemoteImage(url: APIConfig.userAvatarURL(id: id)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Circle()
                .fill(Color(.secondarySystemFill))
                .overlay {
                    Text(String(nickname.prefix(1)).uppercased())
                        .font(.system(size: size * 0.42))
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
