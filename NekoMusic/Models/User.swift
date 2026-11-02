import Foundation

struct User: Codable, Identifiable {
    let id: Int
    let username: String
    let email: String
    let createdAt: String
    let isVip: Bool?
    let vipExpiresAt: String?
}

struct LoginRequest: Codable {
    let email: String
    let password: String
}

struct RegisterRequest: Codable {
    let nickname: String
    let password: String
    let email: String
    let verificationCode: String
}

struct LoginResponse: Codable {
    let success: Bool
    let message: String
    let data: LoginData?
}

struct LoginData: Codable {
    let user: UserData
    let token: String
}

/// 新后端的用户对象字段是 `nickname`；旧数据里是 `username`。
/// 这里兼容两种键名，同时保留 `username` 作为展示用的别名。
struct UserData: Codable {
    let id: Int
    let nickname: String
    let email: String
    let createdAt: String
    let isVip: Bool?
    let vipExpiresAt: String?

    var username: String { nickname }

    enum CodingKeys: String, CodingKey {
        case id, nickname, username, email, createdAt, isVip, vipExpiresAt
    }

    init(id: Int, nickname: String, email: String, createdAt: String, isVip: Bool?, vipExpiresAt: String?) {
        self.id = id
        self.nickname = nickname
        self.email = email
        self.createdAt = createdAt
        self.isVip = isVip
        self.vipExpiresAt = vipExpiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
            ?? container.decodeIfPresent(String.self, forKey: .username)
            ?? "用户"
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        isVip = try container.decodeIfPresent(Bool.self, forKey: .isVip)
        vipExpiresAt = try container.decodeIfPresent(String.self, forKey: .vipExpiresAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(nickname, forKey: .nickname)
        try container.encode(email, forKey: .email)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(isVip, forKey: .isVip)
        try container.encodeIfPresent(vipExpiresAt, forKey: .vipExpiresAt)
    }
}

struct RegisterResponse: Codable {
    let success: Bool
    let message: String
    let data: [String: String]?
}

struct VerificationResponse: Codable {
    let success: Bool
    let message: String
}

struct UpdatePasswordRequest: Codable {
    let oldPassword: String
    let newPassword: String
}

struct UpdatePasswordResponse: Codable {
    let success: Bool
    let message: String
}

struct ResetPasswordRequest: Codable {
    let email: String
    let code: String
    let newPassword: String
}

struct ResetPasswordResponse: Codable {
    let success: Bool
    let message: String
}

// MARK: - 昵称

struct NicknameChangeData: Codable {
    let nickname: String
}

struct NicknameChangeResponse: Codable {
    let success: Bool
    let message: String
    let data: NicknameChangeData?
}

// MARK: - 头像

struct AvatarUploadResponse: Codable {
    let success: Bool?
    let message: String?
    let avatarPath: String?
    let error: String?

    var isOK: Bool { success == true }
}

// MARK: - VIP

struct VipPlan: Codable, Identifiable {
    let id: Int
    let months: Int
    let days: Int
    let priceYuan: Double
    let sortOrder: Int?
    let updatedAt: String?

    var durationText: String {
        var parts: [String] = []
        if months > 0 { parts.append("\(months) 个月") }
        if days > 0 { parts.append("\(days) 天") }
        return parts.isEmpty ? "会员" : parts.joined(separator: " + ")
    }

    var priceText: String { String(format: "¥%.2f", priceYuan) }
}

struct VipPricingResponse: Codable {
    let success: Bool
    let message: String?
    let data: [VipPlan]?
}

struct VipPayRequest: Codable {
    let pricingId: Int
    let payType: String
}

struct VipPayData: Codable {
    let outTradeNo: String?
    let payurl: String?
    let qrcode: String?
}

struct VipPayResponse: Codable {
    let success: Bool
    let message: String?
    let data: VipPayData?
}

// MARK: - 滑块人机验证

struct SliderCaptcha {
    let captchaToken: String
    let bgImage: String
    let sliderImage: String
    let puzzleY: Double
    let bgWidth: Double
    let bgHeight: Double
    let sliderWidth: Double
    let sliderHeight: Double
}

struct SliderCaptchaResponse: Codable {
    let success: Bool
    let message: String?
    let data: SliderCaptchaData?
}

struct SliderCaptchaData: Codable {
    let captchaToken: String
    let bgImage: String
    let sliderImage: String
    let puzzleY: Double
    let bgWidth: Double
    let bgHeight: Double
    let sliderWidth: Double
    let sliderHeight: Double
}

struct DragPoint: Codable {
    let t: Int
    let x: Int
}

struct SliderVerifyRequest: Codable {
    let captchaToken: String
    let captchaOffsetX: Int
    let dragTrace: [DragPoint]
}

struct SliderVerifyData: Codable {
    let captchaPassToken: String
}

struct SliderVerifyResponse: Codable {
    let success: Bool
    let message: String?
    let data: SliderVerifyData?
}
