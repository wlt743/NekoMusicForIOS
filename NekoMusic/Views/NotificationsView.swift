import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var service = NotificationService.shared

    var body: some View {
        Group {
            if service.isLoading && service.items.isEmpty {
                ProgressView("加载中…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.items.isEmpty {
                EmptyStateView(
                    title: "暂无消息",
                    systemImage: "bell.slash",
                    description: "歌单导入完成、有人回复你的评论时会出现在这里"
                )
            } else {
                list
            }
        }
        .navigationTitle("消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if service.unread > 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button("全部已读") {
                        Task { await markAllRead() }
                    }
                }
            }
        }
        .refreshable {
            await load()
        }
        .task {
            if service.items.isEmpty {
                await load()
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(service.items) { item in
                    Button {
                        Task { await handleTap(item) }
                    } label: {
                        NotificationRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                if service.unread > 0 {
                    Text("\(service.unread) 条未读")
                }
            }

            if service.hasMore {
                Section {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack {
                            Spacer()
                            if service.isLoading {
                                ProgressView()
                            } else {
                                Text("加载更早的消息")
                            }
                            Spacer()
                        }
                    }
                    .disabled(service.isLoading)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 动作

    private func load() async {
        guard let token = authService.token else { return }
        await service.refresh(token: token)
    }

    private func loadMore() async {
        guard let token = authService.token else { return }
        await service.loadMore(token: token)
    }

    private func handleTap(_ item: NekoNotification) async {
        guard let token = authService.token else { return }
        if !item.read {
            await service.markRead(ids: [item.id], token: token)
        }
    }

    private func markAllRead() async {
        guard let token = authService.token else { return }
        await service.markRead(ids: [], token: token)
    }
}

// MARK: - 行

private struct NotificationRow: View {
    let item: NekoNotification

    private var iconColor: Color {
        switch item.type {
        case "comment_reply": return .blue
        case "playlist_import": return .accentColor
        case "upload_approved": return .green
        case "upload_rejected": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(iconColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.subheadline)
                        .fontWeight(item.read ? .regular : .semibold)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    if !item.read {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                    }
                }

                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Text(NekoDate.friendly(item.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
