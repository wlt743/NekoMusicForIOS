import SwiftUI
import UIKit

/// 注册前必须完成的滑块人机验证。
/// 流程：GET /api/captcha/slider 取题 → 拖动拼图 → POST /api/captcha/slider/verify 换 captchaPassToken。
struct SliderCaptchaView: View {
    let onSuccess: (String) -> Void
    let onCancel: () -> Void

    @State private var captcha: SliderCaptcha?
    @State private var bgImage: UIImage?
    @State private var pieceImage: UIImage?
    @State private var offset: CGFloat = 0
    @State private var trace: [DragPoint] = []
    @State private var dragStart: Date?
    @State private var isLoading = true
    @State private var isVerifying = false
    @State private var errorMessage: String?

    private let displayWidth: CGFloat = 300

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("安全验证")
                    .font(.headline)
                Spacer()
                Button("取消") { onCancel() }
                    .foregroundColor(.secondary)
            }

            Text("拖动下方滑块，让拼图对齐缺口")
                .font(.caption)
                .foregroundColor(.secondary)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: displayWidth, height: displayHeight)

                if let bgImage = bgImage {
                    Image(uiImage: bgImage)
                        .resizable()
                        .frame(width: displayWidth, height: displayHeight)
                }

                if let pieceImage = pieceImage, captcha != nil {
                    Image(uiImage: pieceImage)
                        .resizable()
                        .frame(width: pieceWidth, height: pieceHeight)
                        .offset(x: offset, y: pieceY)
                }

                if isLoading {
                    ProgressView()
                        .frame(width: displayWidth, height: displayHeight)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )

            // 滑块轨道
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 40)

                Capsule()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: offset + 40, height: 40)

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tint)
                    )
                    .offset(x: offset)
                    .gesture(dragGesture)
            }
            .frame(width: displayWidth, height: 40)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            if isVerifying {
                ProgressView("验证中...")
            }
        }
        .padding(24)
        .task {
            await loadCaptcha()
        }
    }

    // MARK: - Geometry

    private var displayHeight: CGFloat {
        guard let captcha = captcha, captcha.bgWidth > 0 else { return 180 }
        return displayWidth * CGFloat(captcha.bgHeight / captcha.bgWidth)
    }

    private var scale: CGFloat {
        guard let captcha = captcha, captcha.bgWidth > 0 else { return 1 }
        return displayWidth / CGFloat(captcha.bgWidth)
    }

    private var pieceWidth: CGFloat {
        guard let captcha = captcha else { return 52 }
        return CGFloat(captcha.sliderWidth) * scale
    }

    private var pieceHeight: CGFloat {
        guard let captcha = captcha else { return 52 }
        return CGFloat(captcha.sliderHeight) * scale
    }

    private var pieceY: CGFloat {
        guard let captcha = captcha else { return 0 }
        return CGFloat(captcha.puzzleY) * scale
    }

    private var maxOffset: CGFloat {
        max(0, displayWidth - pieceWidth)
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = Date()
                    trace = []
                }
                let newOffset = min(max(0, value.translation.width), maxOffset)
                offset = newOffset
                recordTrace(x: newOffset)
            }
            .onEnded { _ in
                recordTrace(x: offset)
                guard let start = dragStart else { return }
                // 时间太短视为点击，不提交
                if Date().timeIntervalSince(start) < 0.15 {
                    dragStart = nil
                    trace = []
                    offset = 0
                    return
                }
                dragStart = nil
                Task { await submit() }
            }
    }

    private func recordTrace(x: CGFloat) {
        guard let start = dragStart else { return }
        let t = Int(Date().timeIntervalSince(start) * 1000)
        let px = Int((x / scale).rounded())
        trace.append(DragPoint(t: t, x: px))
    }

    // MARK: - Network

    private func loadCaptcha() async {
        isLoading = true
        errorMessage = nil
        offset = 0
        trace = []

        do {
            let captcha = try await AuthService.shared.fetchSliderCaptcha()
            await MainActor.run {
                self.captcha = captcha
                self.bgImage = Self.decodeDataURL(captcha.bgImage)
                self.pieceImage = Self.decodeDataURL(captcha.sliderImage)
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func submit() async {
        guard let captcha = captcha else { return }
        isVerifying = true
        errorMessage = nil

        let offsetX = Int((offset / scale).rounded())
        let points = trace

        do {
            let passToken = try await AuthService.shared.verifySlider(
                captchaToken: captcha.captchaToken,
                offsetX: offsetX,
                trace: points
            )
            await MainActor.run {
                self.isVerifying = false
                self.onSuccess(passToken)
            }
        } catch {
            await MainActor.run {
                self.isVerifying = false
                self.errorMessage = error.localizedDescription
            }
            // 每个 captchaToken 只能用一次，失败后必须换一张
            await loadCaptcha()
        }
    }

    private static func decodeDataURL(_ string: String) -> UIImage? {
        let base64: String
        if let range = string.range(of: "base64,") {
            base64 = String(string[range.upperBound...])
        } else {
            base64 = string
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }
}
