import SwiftUI

/// 首次启动：先确认声明，再选择接口服务器。
/// 应用不内置任何服务地址，也不默认连接任何服务器。
struct OnboardingView: View {
    @ObservedObject var config: ServerConfig
    @State private var step = 0
    @State private var agreed = false
    @State private var customInput = ""
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.09).ignoresSafeArea()
            if step == 0 {
                termsStep
            } else {
                choiceStep
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 第一屏：声明

    private var termsStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("NekoMusic")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                    Text("使用前请阅读以下声明")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))

                    ForEach(Declaration.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            ForEach(section.lines, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.bottom, 2)
                    }

                    Text("勾选并继续，表示你已阅读、理解并同意上述声明。")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 4)
                }
                .padding(20)
            }

            VStack(spacing: 12) {
                Button {
                    agreed.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: agreed ? "checkmark.square.fill" : "square")
                            .font(.title3)
                        Text("我已阅读并同意上述声明")
                            .font(.subheadline)
                        Spacer()
                    }
                    .foregroundStyle(agreed ? Color.accentColor : .white.opacity(0.8))
                    .padding(.horizontal, 20)
                }
                .buttonStyle(.plain)

                Button {
                    config.acceptTerms()
                    step = 1
                } label: {
                    Text("继续")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(agreed ? Color.accentColor : Color.white.opacity(0.12))
                        .foregroundStyle(agreed ? .white : .white.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!agreed)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - 第二屏：资源来源

    private var choiceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择音乐来源")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            Text("本应用不内置曲库。你可以使用社区常用地址，也可以填写自己的接口服务器。内容来源与合法性由你自行确认。")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            optionCard(
                title: "使用 NekoMusic 资源",
                subtitle: "社区常用地址，由第三方提供与维护",
                icon: "music.note.house"
            ) {
                config.usePreset()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.white.opacity(0.8))
                    Text("自己配置")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                TextField("https://你的服务器地址", text: $customInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button {
                    if config.useCustom(customInput) {
                        errorText = nil
                    } else {
                        errorText = "地址无效，请填入以 http:// 或 https:// 开头的完整地址"
                    }
                } label: {
                    Text("使用这个地址")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.14))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()

            Button {
                step = 0
            } label: {
                Text("返回声明确认")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .padding(20)
    }

    private func optionCard(title: String, subtitle: String, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

/// 声明正文（改写版，按应用实际行为描述）
enum Declaration {
    struct Section {
        let title: String
        let lines: [String]
    }

    static let sections: [Section] = [
        Section(title: "一、技术架构", lines: [
            "1. 本应用是纯本地音乐播放器客户端，开发者不运营音乐服务，不存储、不上传、不中转、不筛选、不编辑任何音乐内容。",
            "2. 应用不内置曲库，也不默认连接任何接口服务器。首次启动时，需要你自行选择或填写接口地址，内容来源完全由你决定。",
            "3. 播放与下载均在你的设备与你指定的服务器之间直接进行，开发者不参与该传输，也不会在自己的服务器上保存内容副本。",
            "4. 应用对第三方接口的适配属于通用技术能力，不代表开发者与该服务器之间存在合作、授权或背书关系。",
        ]),
        Section(title: "二、使用边界", lines: [
            "1. 你应自行确保所使用的接口服务器及获取的内容具有合法授权。",
            "2. 禁止利用本应用接入、下载或传播未经授权的音乐作品。",
            "3. 禁止发布盗版链接、侵权资源教程，或引导他人获取无版权内容。",
        ]),
        Section(title: "三、通知与处置", lines: [
            "如权利人、平台或管理方就某一具体接口地址发出含有初步证据的通知，开发者将对该地址断开适配或屏蔽，并留存处理记录。该处置针对具体地址，不构成对其他地址的普遍审查义务。",
        ]),
        Section(title: "四、责任边界", lines: [
            "开发者不对你自行配置的第三方服务器内容承担审核责任，你需要自行承担合法使用义务。本声明不构成对任何第三方内容的授权、认可或背书。",
        ]),
    ]
}
