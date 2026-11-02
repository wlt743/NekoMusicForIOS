import SwiftUI
import UIKit

/// 会员中心：展示服务端在售套餐，下单后跳转支付页。
struct VipView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.openURL) private var openURL

    @State private var plans: [VipPlan] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedPlan: VipPlan?
    @State private var showPayOptions = false
    @State private var payingPlanId: Int?
    @State private var alertMessage = ""
    @State private var showAlert = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                EmptyStateView(
                    title: "加载失败",
                    systemImage: "crown",
                    description: error,
                    actionTitle: "重试"
                ) {
                    Task { await load() }
                }
            } else if plans.isEmpty {
                EmptyStateView(
                    title: "暂无在售套餐",
                    systemImage: "crown",
                    description: "稍后再来看看"
                )
            } else {
                content
            }
        }
        .navigationTitle("会员中心")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if plans.isEmpty {
                await load()
            }
        }
        .confirmationDialog("选择支付方式", isPresented: $showPayOptions, titleVisibility: .visible) {
            Button("支付宝") {
                guard let plan = selectedPlan else { return }
                startPay(plan, type: "alipay")
            }
            Button("微信支付") {
                guard let plan = selectedPlan else { return }
                startPay(plan, type: "wxpay")
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let plan = selectedPlan {
                Text("\(plan.durationText)　\(plan.priceText)")
            }
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定") {}
        } message: {
            Text(alertMessage)
        }
    }

    private var content: some View {
        List {
            Section {
                statusCard
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: Layout.horizontalPadding, bottom: 8, trailing: Layout.horizontalPadding))
            }

            Section {
                ForEach(plans) { plan in
                    Button {
                        guard authService.isLoggedIn else {
                            alertMessage = "请先登录后再开通会员"
                            showAlert = true
                            return
                        }
                        selectedPlan = plan
                        showPayOptions = true
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plan.durationText)
                                    .font(.headline)
                                Text("折合 \(perDayText(plan)) / 天")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if payingPlanId == plan.id {
                                ProgressView()
                            } else {
                                Text(plan.priceText)
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.orange)
                            }

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("在售套餐")
            } footer: {
                Text("下单后会跳转到支付页面。开通结果以服务端为准，可重新进入本页刷新会员状态。")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    private var statusCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "crown.fill")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
                .frame(width: 54, height: 54)
                .background(Color.orange.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                if authService.currentUser?.isVip == true {
                    Text("会员生效中")
                        .font(.headline)
                    if let expiry = authService.currentUser?.vipExpiresAt, !expiry.isEmpty {
                        Text("到期时间 \(expiry.prefix(10))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if authService.isLoggedIn {
                    Text("尚未开通会员")
                        .font(.headline)
                    Text("开通后可享受更完整的曲库与音质")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("登录后查看会员状态")
                        .font(.headline)
                    Text("套餐价格对所有访客可见")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func perDayText(_ plan: VipPlan) -> String {
        let days = max(plan.months * 30 + plan.days, 1)
        return String(format: "¥%.2f", plan.priceYuan / Double(days))
    }

    // MARK: - 数据

    private func load() async {
        isLoading = plans.isEmpty
        errorMessage = nil

        do {
            let response: VipPricingResponse = try await NetworkService.shared.get(url: APIConfig.vipPricingURL())
            guard response.success else {
                throw NetworkError.serverError(response.message ?? "获取会员套餐失败")
            }
            await MainActor.run {
                self.plans = (response.data ?? []).sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    /// 先确认手机上装了对应的支付 App，否则支付链接打不开
    private func startPay(_ plan: VipPlan, type: String) {
        let appName = type == "alipay" ? "支付宝" : "微信"
        let scheme = type == "alipay" ? "alipay://" : "weixin://"

        guard let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) else {
            alertMessage = "这台手机没有安装\(appName)，请先安装后再试，或改用另一种支付方式"
            showAlert = true
            return
        }

        Task { await pay(plan, type: type) }
    }

    private func pay(_ plan: VipPlan, type: String) async {
        guard let token = authService.token else {
            alertMessage = "请先登录"
            showAlert = true
            return
        }

        payingPlanId = plan.id
        defer { payingPlanId = nil }

        do {
            let response: VipPayResponse = try await NetworkService.shared.post(
                url: APIConfig.vipPayCreateURL(),
                body: VipPayRequest(pricingId: plan.id, payType: type),
                token: token
            )

            if response.success, let payurl = response.data?.payurl, let url = URL(string: payurl) {
                openURL(url)
            } else {
                alertMessage = response.message ?? "下单失败，请稍后再试"
                showAlert = true
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
}
