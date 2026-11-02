import SwiftUI
import AVFoundation

/// 手机端扫码确认登录：扫 PC 上的 nekomusic://qrlogin?sid=... 后调用 scan/confirm
struct QRLoginView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var sessionId = ""
    @State private var manualInput = ""
    @State private var scanned = false
    @State private var isWorking = false
    @State private var message = ""
    @State private var showMessage = false
    @State private var finished = false
    @State private var cameraAuthorized = false

    var body: some View {
        NavigationStack {
            Form {
                if !scanned {
                    Section {
                        QRScannerContainer { code in
                            handleScanned(code)
                        }
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.black)
                    } header: {
                        Text("对准电脑上的二维码")
                    } footer: {
                        Text("扫描后需要你确认一次，才会为电脑登录。")
                    }

                    Section {
                        TextField("或手动粘贴二维码内容", text: $manualInput, axis: .vertical)
                            .lineLimit(1...3)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button("使用这段内容") {
                            handleScanned(manualInput)
                        }
                        .disabled(manualInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } footer: {
                        Text("模拟器没有摄像头时可以用这个入口（内容是 nekomusic://qrlogin?sid=...）。")
                    }
                } else {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("已识别二维码")
                        }
                        LabeledContent("会话", value: String(sessionId.prefix(10)) + "…")

                        Button("在电脑上登录") {
                            Task { await confirm(approve: true) }
                        }
                        .disabled(isWorking)

                        Button("拒绝这次登录", role: .destructive) {
                            Task { await confirm(approve: false) }
                        }
                        .disabled(isWorking)

                        Button("重新扫描") {
                            scanned = false
                            sessionId = ""
                            finished = false
                        }
                        .disabled(isWorking)
                    } footer: {
                        if let me = authService.currentUser {
                            Text("确认后，电脑会以 \(me.nickname) 的身份登录。请只在你自己发起登录时确认。")
                        }
                    }
                }
            }
            .navigationTitle("扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert(finished ? "完成" : "提示", isPresented: $showMessage) {
                if finished {
                    Button("好") { dismiss() }
                } else {
                    Button("确定") {}
                }
            } message: {
                Text(message)
            }
            .task {
                requestCamera()
            }
        }
    }

    // MARK: - 流程

    private func handleScanned(_ code: String) {
        guard let sid = Self.parseSessionId(code) else {
            message = "不是有效的 NekoMusic 登录二维码"
            showMessage = true
            return
        }
        guard !sid.isEmpty else { return }
        sessionId = sid
        Task { await markScanned() }
    }

    private static func parseSessionId(_ code: String) -> String? {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), url.scheme == "nekomusic" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "sid" }?.value
        }
        // 允许直接粘贴 32 位 sessionId
        if text.count >= 16, !text.contains("://"), text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            return text
        }
        return nil
    }

    private func markScanned() async {
        guard let token = authService.token else {
            await MainActor.run {
                message = "请先登录"
                showMessage = true
            }
            return
        }
        await MainActor.run { isWorking = true }
        defer { Task { @MainActor in isWorking = false } }

        do {
            struct Body: Encodable { let sessionId: String }
            let _: QRStatusResponse = try await NetworkService.shared.post(
                url: APIConfig.qrScanURL(),
                body: Body(sessionId: sessionId),
                token: token
            )
            await MainActor.run { scanned = true }
        } catch {
            await MainActor.run {
                message = error.localizedDescription
                showMessage = true
            }
        }
    }

    private func confirm(approve: Bool) async {
        guard let token = authService.token else { return }
        await MainActor.run { isWorking = true }
        defer { Task { @MainActor in isWorking = false } }

        do {
            struct Body: Encodable {
                let sessionId: String
                let approve: Bool
            }
            let response: QRStatusResponse = try await NetworkService.shared.post(
                url: APIConfig.qrConfirmURL(),
                body: Body(sessionId: sessionId, approve: approve),
                token: token
            )
            await MainActor.run {
                finished = true
                message = approve
                    ? "电脑已登录（\(response.data?.status ?? "confirmed")）"
                    : "已拒绝这次登录"
                showMessage = true
            }
        } catch {
            await MainActor.run {
                message = error.localizedDescription
                showMessage = true
            }
        }
    }

    private func requestCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in cameraAuthorized = granted }
        }
    }
}

// MARK: - 响应模型

struct QRStatusData: Codable {
    let status: String?
}

struct QRStatusResponse: Codable {
    let success: Bool
    let message: String?
    let data: QRStatusData?
}

// MARK: - 相机扫码

struct QRScannerContainer: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasDelivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showPlaceholder()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showPlaceholder()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    private func showPlaceholder() {
        let label = UILabel()
        label.text = "当前设备没有可用的摄像头\n请用下方手动输入"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .lightGray
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasDelivered,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        hasDelivered = true
        onCode?(value)
    }
}
