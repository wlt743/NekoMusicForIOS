import SwiftUI

/// 来源选择列表：首次启动和设置页共用。
struct SourcePickerList: View {
    @ObservedObject var config: ServerConfig
    @State private var pendingKind: ServerConfig.SourceKind?
    @State private var showForm = false

    var body: some View {
        VStack(spacing: 10) {
            ForEach(ServerConfig.SourceKind.allCases) { kind in
                Button {
                    if kind == .neko {
                        Task { await applyPreset() }
                    } else {
                        pendingKind = kind
                        showForm = true
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: kind.icon)
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(kind.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                if !kind.playbackSupported {
                                    Text("播放适配中")
                                        .font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.22))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(kind.subtitle)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showForm, onDismiss: { pendingKind = nil }) {
            if let kind = pendingKind {
                SourceSetupSheet(config: config, kind: kind)
            }
        }
    }

    private func applyPreset() async {
        _ = await config.verifyAndSave(kind: .neko, rawURL: ServerConfig.presetURL,
                                       credentials: .init())
    }
}

/// 各类来源的填写表单 + 连通性校验
struct SourceSetupSheet: View {
    @ObservedObject var config: ServerConfig
    let kind: ServerConfig.SourceKind
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section(kind.title) {
                    TextField(placeholder, text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if kind == .subsonic || kind == .jellyfin {
                        TextField("用户名", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码", text: $password)
                    }
                    if kind == .jellyfin {
                        TextField("API Key（可选，填了优先用 Key）", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if kind == .generic {
                        TextField("访问令牌（可选）", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !kind.playbackSupported {
                    Section {
                        Text("该来源当前只支持保存配置与连通性校验，播放适配仍在开发中。选择后主界面可能没有内容。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "正在校验…" : "测试连接并保存")
                            Spacer()
                        }
                    }
                    .disabled(busy || url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("配置来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if config.baseURL.isEmpty == false, kind == config.kind {
                    url = config.baseURL
                    username = config.credentials.username
                    password = config.credentials.password
                    token = config.credentials.token
                }
            }
        }
    }

    private var placeholder: String {
        switch kind {
        case .generic: return "https://接口地址"
        default: return "https://你的服务器地址"
        }
    }

    private func save() {
        busy = true
        error = nil
        let creds = ServerConfig.Credentials(username: username, password: password, token: token)
        Task {
            let failure = await config.verifyAndSave(kind: kind, rawURL: url, credentials: creds)
            busy = false
            if let failure {
                error = failure
            } else {
                dismiss()
            }
        }
    }
}

/// 设置里的「接口服务器」：查看当前配置并切换
struct ServerConfigView: View {
    @ObservedObject var config: ServerConfig

    var body: some View {
        List {
            Section("当前配置") {
                LabeledContent("来源", value: config.kind?.title ?? "未配置")
                LabeledContent("地址", value: config.baseURL.isEmpty ? "未配置" : config.baseURL)
                if !config.isPlaybackSupported, config.kind != nil {
                    Text("该来源的播放适配还在开发中。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("切换来源") {
                SourcePickerList(config: config)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 4)
            }

            Section {
                Text("切换来源后会重新注册客户端实例；已缓存的列表与封面可在「清除缓存」处理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("接口服务器")
        .navigationBarTitleDisplayMode(.inline)
    }
}
