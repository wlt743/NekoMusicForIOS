import Foundation
import SwiftUI

/// 接口服务器配置。
///
/// 应用本身不内置、不默认连接任何服务；首次启动由用户明确选择或填写地址，
/// 内容来源与合法性由用户自行负责。
@MainActor
final class ServerConfig: ObservableObject {
    static let shared = ServerConfig()

    enum Mode: String {
        case none
        case preset      // 社区常用地址
        case custom      // 用户自填
    }

    /// 社区常用地址（仅供用户选择，不是默认值）
    static let presetURL = "https://music.nekocore.cn"

    private enum Keys {
        static let mode = "neko.server.mode"
        static let custom = "neko.server.custom"
        static let onboarded = "neko.onboarded"
        static let termsAccepted = "neko.terms.accepted"
    }

    @Published private(set) var mode: Mode
    @Published private(set) var baseURL: String
    @Published private(set) var hasAcceptedTerms: Bool

    private let defaults = UserDefaults.standard

    private init() {
        let savedMode = Mode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .none
        mode = savedMode
        let custom = defaults.string(forKey: Keys.custom) ?? ""
        baseURL = savedMode == .preset ? Self.presetURL : (savedMode == .custom ? custom : "")
        hasAcceptedTerms = defaults.bool(forKey: Keys.termsAccepted)
        APIConfig.baseURL = baseURL
    }

    /// 首次启动流程是否走完（同意了协议且选好了服务器）
    var isReady: Bool {
        hasAcceptedTerms && !baseURL.isEmpty && URL(string: baseURL) != nil
    }

    func acceptTerms() {
        hasAcceptedTerms = true
        defaults.set(true, forKey: Keys.termsAccepted)
    }

    func usePreset() {
        apply(url: Self.presetURL, mode: .preset)
    }

    /// 自配置：只接受 http/https，自动去掉结尾斜杠
    @discardableResult
    func useCustom(_ raw: String) -> Bool {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return false }
        apply(url: text, mode: .custom)
        return true
    }

    private func apply(url: String, mode: Mode) {
        baseURL = url
        self.mode = mode
        APIConfig.baseURL = url
        defaults.set(mode.rawValue, forKey: Keys.mode)
        if mode == .custom {
            defaults.set(url, forKey: Keys.custom)
        }
    }

    /// 设置页里改地址用
    func update(_ raw: String) -> Bool { useCustom(raw) }
}
