import SwiftUI
import PhotosUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var notificationService = NotificationService.shared

    @State private var showLogin = false
    @State private var avatarVersion = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if authService.isLoggedIn, let user = authService.currentUser {
                        HStack(spacing: 16) {
                            AvatarView(user: user, version: avatarVersion)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.nickname)
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                Text(user.email)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if user.isVip == true {
                                    Label("VIP", systemImage: "crown.fill")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            showLogin = true
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(.largeTitle))
                                    .foregroundStyle(.secondary)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("点击登录")
                                        .font(.title3)
                                        .fontWeight(.semibold)
                                    Text("登录后享受更多功能")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }

                if authService.isLoggedIn {
                    Section {
                        NavigationLink {
                            VipView()
                        } label: {
                            HStack {
                                Label(
                                    authService.currentUser?.isVip == true ? "会员已开通" : "开通会员",
                                    systemImage: "crown.fill"
                                )
                                Spacer()
                                if let expiry = authService.currentUser?.vipExpiresAt, !expiry.isEmpty {
                                    Text(String(expiry.prefix(10)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section("音乐") {
                        NavigationLink {
                            NotificationsView()
                        } label: {
                            Label("消息", systemImage: "bell.fill")
                                .badge(notificationService.unread)
                        }

                        NavigationLink {
                            FavoritesView()
                        } label: {
                            Label("我的收藏", systemImage: "heart.fill")
                        }

                        NavigationLink {
                            PlaylistsView()
                        } label: {
                            Label("我的歌单", systemImage: "music.note.list")
                        }

                        NavigationLink {
                            FavoritePlaylistsView()
                        } label: {
                            Label("收藏歌单", systemImage: "bookmark")
                        }

                        NavigationLink {
                            UploadedMusicView()
                        } label: {
                            Label("我上传的音乐", systemImage: "arrow.up.circle")
                        }
                    }
                }

                Section("其他") {
                    if authService.isLoggedIn {
                        NavigationLink {
                            QRLoginView()
                        } label: {
                            Label("扫码登录（给电脑用）", systemImage: "qrcode.viewfinder")
                        }
                    }

                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }

                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于", systemImage: "info.circle")
                    }
                }

                if authService.isLoggedIn {
                    Section {
                        Button("退出登录", role: .destructive) {
                            authService.logout()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .listRowBackground(Color(.secondarySystemGroupedBackground).opacity(0.62))
            .background { WallpaperBackdrop() }
            .navigationTitle("我的")
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .task(id: authService.isLoggedIn) {
            guard authService.isLoggedIn, let token = authService.token else {
                notificationService.clear()
                return
            }
            await notificationService.refresh(token: token)
        }
        .onReceive(NotificationCenter.default.publisher(for: .avatarDidChange)) { _ in
            avatarVersion += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard authService.isLoggedIn, let token = authService.token else { return }
            let since = notificationService.latestId
            Task {
                await notificationService.refresh(token: token, since: since > 0 ? since : nil)
            }
        }
    }
}

private struct AvatarView: View {
    let user: UserData
    var version: Int = 0

    var body: some View {
        RemoteImage(url: APIConfig.userAvatarURL(id: user.id) + "?v=\(version)") { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Circle()
                .fill(Color(.secondarySystemFill))
                .overlay {
                    Text(String(user.nickname.prefix(1)).uppercased())
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: 60, height: 60)
        .clipShape(Circle())
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var appearance = AppearanceSettings.shared
    @State private var cacheSize = "—"

    @State private var showChangePassword = false
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        List {
            if authService.isLoggedIn {
                Section("账户") {
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        HStack {
                            Label("更换头像", systemImage: "person.crop.circle")
                            Spacer()
                            if isUploadingAvatar {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isUploadingAvatar)
                    .onChange(of: avatarItem) { item in
                        guard let item = item else { return }
                        Task { await uploadAvatar(item) }
                    }

                    NavigationLink {
                        NicknameEditView()
                    } label: {
                        Label("修改昵称", systemImage: "pencil")
                    }

                    Button("修改密码") {
                        showChangePassword = true
                    }
                }
            }

            Section("外观") {
                Picker("外观模式", selection: $appearance.appearanceMode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)

                NavigationLink {
                    AppearanceView()
                } label: {
                    Label("主题色与壁纸", systemImage: "paintpalette")
                }
            }

            Section("存储") {
                Button {
                    CacheService.clear()
                    cacheSize = CacheService.formattedSize()
                } label: {
                    HStack {
                        Label("清除缓存", systemImage: "trash")
                        Spacer()
                        Text(cacheSize)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("内容") {
                NavigationLink {
                    BlacklistView()
                } label: {
                    Label("黑名单", systemImage: "hand.raised.slash")
                }
            }

            Section("信息") {
                LabeledContent("版本", value: appVersion)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .task {
            cacheSize = CacheService.formattedSize()
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert("修改密码", isPresented: $showChangePassword) {
            SecureField("当前密码", text: $oldPassword)
            SecureField("新密码", text: $newPassword)
            SecureField("确认新密码", text: $confirmPassword)
            Button("确认") {
                Task { await changePassword() }
            }
            Button("取消", role: .cancel) {
                clearPasswordFields()
            }
        }
        .alert(alertMessage, isPresented: $showAlert) {
            Button("确定") {}
        }
    }

    private func changePassword() async {
        guard newPassword == confirmPassword else {
            alertMessage = "两次输入的密码不一致"
            showAlert = true
            return
        }

        guard newPassword.count >= 6 else {
            alertMessage = "新密码至少 6 位"
            showAlert = true
            return
        }

        do {
            let response = try await authService.changePassword(
                oldPassword: oldPassword,
                newPassword: newPassword
            )
            alertMessage = response.message
            showAlert = true
            if response.success {
                clearPasswordFields()
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func clearPasswordFields() {
        oldPassword = ""
        newPassword = ""
        confirmPassword = ""
    }

    // MARK: - 头像

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        isUploadingAvatar = true
        defer {
            isUploadingAvatar = false
            avatarItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = Self.prepareAvatarData(image) else {
                alertMessage = "无法读取所选图片"
                showAlert = true
                return
            }

            let response = try await authService.uploadAvatar(jpeg)
            if response.isOK {
                RemoteImageCache.shared.clear()
                NotificationCenter.default.post(name: .avatarDidChange, object: nil)
                alertMessage = response.message ?? "头像已更新"
            } else {
                alertMessage = response.error ?? response.message ?? "上传失败"
            }
            showAlert = true
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    /// 缩到 512pt 以内再压成 JPEG，避免超过 10MiB 限制
    private static func prepareAvatarData(_ image: UIImage, maxSide: CGFloat = 512) -> Data? {
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
}

// MARK: - 关于

struct AboutView: View {
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)

                    Text("NekoMusic")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("版本 \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("一款简洁优雅的音乐播放器")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            Section {
                LabeledContent("开发者", value: "Neko Team")
                LabeledContent("平台", value: "iOS")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 修改昵称

struct NicknameEditView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var isSaving = false
    @State private var message = ""
    @State private var showMessage = false
    @State private var succeeded = false

    var body: some View {
        Form {
            Section {
                TextField("昵称", text: $nickname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("新昵称")
            } footer: {
                Text("1–20 个字符，不能包含违禁词；昵称允许重复。")
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("保存")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isSaving)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("修改昵称")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            nickname = authService.currentUser?.nickname ?? ""
        }
        .alert(succeeded ? "已保存" : "提示", isPresented: $showMessage) {
            if succeeded {
                Button("好") { dismiss() }
            } else {
                Button("确定") {}
            }
        } message: {
            Text(message)
        }
    }

    private func save() async {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "昵称不能为空"
            showMessage = true
            return
        }
        guard trimmed.count <= 20 else {
            message = "昵称长度需在 1-20 之间"
            showMessage = true
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let response = try await authService.changeNickname(trimmed)
            succeeded = response.success
            message = response.message
            showMessage = true
        } catch {
            message = error.localizedDescription
            showMessage = true
        }
    }
}
