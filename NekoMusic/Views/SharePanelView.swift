import SwiftUI
import UIKit

/// 系统分享面板的 SwiftUI 封装（「更多」用）
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - 渠道

private struct ShareChannel: Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let scheme: String
}

// MARK: - 官方图标加载

/// 通过 iTunes Lookup 拉取对应 App 的官方图标并缓存，避免手绘图标的版权与辨识度问题。
final class AppIconLoader {
    static let shared = AppIconLoader()

    private var memory: [String: UIImage] = [:]

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    func icon(for bundleID: String) async -> UIImage? {
        if let cached = memory[bundleID] { return cached }

        let file = directory.appendingPathComponent(bundleID + ".png")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory[bundleID] = image
            return image
        }

        guard let lookupURL = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleID)&country=cn"),
              let (lookupData, _) = try? await URLSession.shared.data(from: lookupURL),
              let json = try? JSONSerialization.jsonObject(with: lookupData) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first else {
            return nil
        }

        let artwork = (first["artworkUrl512"] as? String) ?? (first["artworkUrl100"] as? String)
        guard let artwork = artwork, let iconURL = URL(string: artwork),
              let (imageData, _) = try? await URLSession.shared.data(from: iconURL),
              let image = UIImage(data: imageData) else {
            return nil
        }

        try? imageData.write(to: file)
        memory[bundleID] = image
        return image
    }
}

// MARK: - 分享面板

struct SharePanelView: View {
    let text: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showSystemShare = false
    @State private var showVideoRender = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var copiedToast = false
    @State private var icons: [String: UIImage] = [:]

    private let channels: [ShareChannel] = [
        ShareChannel(id: "wechat", name: "微信", bundleID: "com.tencent.xin", scheme: "weixin://"),
        ShareChannel(id: "qq", name: "QQ", bundleID: "com.tencent.mqq", scheme: "mqq://"),
        ShareChannel(id: "x", name: "X", bundleID: "com.atebits.Tweetie2", scheme: "twitter://"),
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        VStack(spacing: 0) {
            header

            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(channels) { channel in
                    channelButton(channel)
                }

                actionButton(title: "复制链接", icon: "link", color: .secondary) {
                    UIPasteboard.general.string = text
                    copiedToast = true
                }

                actionButton(title: "更多", icon: "ellipsis", color: .secondary) {
                    showSystemShare = true
                }

                actionButton(title: "分享视频", icon: "film", color: .secondary) {
                    showVideoRender = true
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)

            Spacer(minLength: 16)

            Divider()

            Button {
                dismiss()
            } label: {
                Text("取消")
                    .font(.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.plain)
        }
        .background(Color(.systemBackground))
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.hidden)
        .overlay(alignment: .bottom) {
            if copiedToast {
                Text("链接已复制")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 72)
            }
        }
        .onChange(of: copiedToast) { value in
            guard value else { return }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copiedToast = false
            }
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定") {}
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showSystemShare) {
            ActivityView(items: [text])
        }
        .task {
            for channel in channels {
                if let image = await AppIconLoader.shared.icon(for: channel.bundleID) {
                    icons[channel.id] = image
                }
            }
        }
    }

    private var header: some View {
        ZStack {
            Text("分享")
                .font(.headline)

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - 按钮

    private func channelButton(_ channel: ShareChannel) -> some View {
        Button {
            // 复制文案后直接打开对应 App（没有 SDK 时的折中）
            UIPasteboard.general.string = text
            if let url = URL(string: channel.scheme), UIApplication.shared.canOpenURL(url) {
                openURL(url)
            } else {
                alertMessage = "没有检测到\(channel.name)，内容已复制到剪贴板"
                showAlert = true
            }
        } label: {
            VStack(spacing: 7) {
                iconView(channel)
                Text(channel.name)
                    .font(.caption2)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func iconView(_ channel: ShareChannel) -> some View {
        if let image = icons[channel.id] {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(.secondarySystemFill))
                .frame(width: 54, height: 54)
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                }
        }
    }

    private func actionButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                        .frame(width: 54, height: 54)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}
