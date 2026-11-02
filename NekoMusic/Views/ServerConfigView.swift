import SwiftUI

/// 设置里的「接口服务器」：运行期也能改地址。
struct ServerConfigView: View {
    @ObservedObject var config: ServerConfig
    @EnvironmentObject var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss

    @State private var input: String = ""
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        List {
            Section("当前配置") {
                LabeledContent("地址", value: config.baseURL.isEmpty ? "未配置" : config.baseURL)
                LabeledContent("来源", value: sourceLabel)
            }

            Section("修改") {
                Button {
                    apply(.preset)
                } label: {
                    Label("使用社区常用地址", systemImage: "music.note.house")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("自定义地址")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("https://你的服务器地址", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("保存自定义地址") { apply(.custom) }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.vertical, 4)
            }

            Section {
                Text("切换地址后，客户端的实例身份会重新注册；已缓存的列表与封面请到「清除缓存」处理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("接口服务器")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            input = config.mode == .custom ? config.baseURL : ""
        }
        .alert(message ?? "", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好") {}
        }
    }

    private var sourceLabel: String {
        switch config.mode {
        case .preset: return "社区常用地址"
        case .custom: return "自定义"
        case .none: return "未配置"
        }
    }

    private enum ApplyMode { case preset, custom }

    private func apply(_ mode: ApplyMode) {
        let ok: Bool
        switch mode {
        case .preset:
            config.usePreset()
            ok = true
        case .custom:
            ok = config.useCustom(input)
        }
        if ok {
            // 实例与令牌绑定在旧服务器上，换服务器必须整体作废
            ClientIdentityService.shared.resetForNewServer()
            isError = false
            message = "已切换到新的服务器地址，返回首页重新加载即可生效"
        } else {
            isError = true
            message = "地址无效，请填入以 http:// 或 https:// 开头的完整地址"
        }
    }
}
