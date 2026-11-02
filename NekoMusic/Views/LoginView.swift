import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var isLoginMode = true
    @State private var nickname = ""
    @State private var email = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var captchaPassToken: String?
    @State private var showCaptcha = false
    @State private var isLoading = false
    @State private var isSendingCode = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showCodeSent = false
    @State private var showForgotPassword = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.house.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)

                        Text("NekoMusic")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Picker("模式", selection: $isLoginMode) {
                        Text("登录").tag(true)
                        Text("注册").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                Section {
                    if !isLoginMode {
                        TextField("昵称", text: $nickname)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                    }

                    TextField("邮箱", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("密码", text: $password)
                        .textContentType(isLoginMode ? .password : .newPassword)

                    if !isLoginMode {
                        HStack {
                            TextField("邮箱验证码", text: $verificationCode)
                                .keyboardType(.numberPad)

                            Button {
                                Task { await requestCaptcha() }
                            } label: {
                                if isSendingCode {
                                    ProgressView()
                                } else {
                                    Text("发送验证码")
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isSendingCode)
                        }
                    }
                } footer: {
                    if !isLoginMode {
                        Text("发送验证码前需要完成滑块验证")
                    } else {
                        Text("使用注册邮箱和密码登录")
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text(isLoginMode ? "登录" : "注册")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isLoading)
                    .listRowBackground(Color.clear)
                }

                if isLoginMode {
                    Section {
                        Button("忘记密码？") {
                            showForgotPassword = true
                        }
                        .frame(maxWidth: .infinity)
                    } footer: {
                        Text("通过注册邮箱接收验证码重置密码")
                    }
                }
            }
            .navigationTitle(isLoginMode ? "登录" : "注册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showCaptcha) {
                SliderCaptchaView(
                    onSuccess: { passToken in
                        showCaptcha = false
                        captchaPassToken = passToken
                        Task { await sendVerificationCode() }
                    },
                    onCancel: {
                        showCaptcha = false
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .alert("提示", isPresented: $showError) {
                Button("确定") {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("验证码已发送", isPresented: $showCodeSent) {
                Button("确定") {}
            } message: {
                Text("请查收邮箱并填写 6 位验证码")
            }
            .sheet(isPresented: $showForgotPassword) {
                ForgotPasswordView()
                    .environmentObject(authService)
            }
        }
    }

    // MARK: - 操作

    private func requestCaptcha() async {
        guard !email.isEmpty else {
            show(message: "请先填写邮箱")
            return
        }
        guard email.contains("@") else {
            show(message: "邮箱格式不正确")
            return
        }
        if nickname.isEmpty {
            nickname = String(email.split(separator: "@").first ?? "用户")
        }
        await MainActor.run { showCaptcha = true }
    }

    private func sendVerificationCode() async {
        guard let passToken = captchaPassToken else { return }
        await MainActor.run { isSendingCode = true }

        do {
            let response = try await authService.sendVerificationCode(
                email: email,
                nickname: nickname,
                captchaPassToken: passToken
            )
            await MainActor.run {
                isSendingCode = false
                if response.success {
                    showCodeSent = true
                } else {
                    errorMessage = response.message
                    showError = true
                }
            }
        } catch {
            await MainActor.run {
                isSendingCode = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func submit() async {
        guard !email.isEmpty, !password.isEmpty else {
            show(message: "请填写邮箱和密码")
            return
        }

        if !isLoginMode {
            guard !nickname.isEmpty else {
                show(message: "请填写昵称")
                return
            }
            guard !verificationCode.isEmpty else {
                show(message: "请填写邮箱验证码")
                return
            }
        }

        await MainActor.run { isLoading = true }

        do {
            if isLoginMode {
                let response = try await authService.login(email: email, password: password)
                await MainActor.run {
                    isLoading = false
                    if response.success {
                        dismiss()
                    } else {
                        errorMessage = response.message
                        showError = true
                    }
                }
            } else {
                let response = try await authService.register(
                    nickname: nickname,
                    password: password,
                    email: email,
                    verificationCode: verificationCode
                )
                await MainActor.run {
                    isLoading = false
                    if response.success {
                        errorMessage = "注册成功，请使用邮箱和密码登录"
                        showError = true
                        isLoginMode = true
                        password = ""
                        verificationCode = ""
                    } else {
                        errorMessage = response.message
                        showError = true
                    }
                }
            }
        } catch {
            await MainActor.run {
                isLoading = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func show(message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - 找回密码

struct ForgotPasswordView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSending = false
    @State private var isSubmitting = false
    @State private var message = ""
    @State private var showMessage = false
    @State private var succeeded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("注册邮箱", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("邮箱")
                } footer: {
                    Text("重置密码的验证码会发送到这个邮箱，无需滑块验证")
                }

                Section {
                    HStack {
                        TextField("邮箱验证码", text: $code)
                            .keyboardType(.numberPad)

                        Button {
                            Task { await sendCode() }
                        } label: {
                            if isSending {
                                ProgressView()
                            } else {
                                Text("发送验证码")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isSending || email.isEmpty)
                    }

                    SecureField("新密码", text: $newPassword)
                        .textContentType(.newPassword)

                    SecureField("确认新密码", text: $confirmPassword)
                        .textContentType(.newPassword)
                } footer: {
                    Text("新密码至少 6 位")
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("重置密码")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isSubmitting)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("找回密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert(succeeded ? "密码已重置" : "提示", isPresented: $showMessage) {
                if succeeded {
                    Button("去登录") { dismiss() }
                } else {
                    Button("确定") {}
                }
            } message: {
                Text(message)
            }
        }
    }

    private func sendCode() async {
        guard email.contains("@") else {
            message = "请输入正确的邮箱"
            showMessage = true
            return
        }
        isSending = true
        defer { isSending = false }

        do {
            let response = try await authService.sendResetCode(email: email)
            message = response.success ? "验证码已发送，请查收邮箱" : response.message
            showMessage = true
        } catch {
            message = error.localizedDescription
            showMessage = true
        }
    }

    private func submit() async {
        guard email.contains("@") else {
            message = "请输入正确的邮箱"
            showMessage = true
            return
        }
        guard !code.isEmpty else {
            message = "请填写邮箱验证码"
            showMessage = true
            return
        }
        guard newPassword.count >= 6 else {
            message = "新密码至少 6 位"
            showMessage = true
            return
        }
        guard newPassword == confirmPassword else {
            message = "两次输入的新密码不一致"
            showMessage = true
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let response = try await authService.resetPassword(
                email: email,
                code: code,
                newPassword: newPassword
            )
            succeeded = response.success
            message = response.success ? "密码已重置，请使用新密码登录" : response.message
            showMessage = true
        } catch {
            message = error.localizedDescription
            showMessage = true
        }
    }
}
