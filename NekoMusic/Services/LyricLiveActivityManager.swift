import ActivityKit
import Foundation

/// 管理锁屏歌词实时活动（iOS 16.1+）
@available(iOS 16.1, *)
@MainActor
final class LyricLiveActivityManager {
    static let shared = LyricLiveActivityManager()

    private var activity: Activity<LyricActivityAttributes>?
    private var lastState: LyricActivityAttributes.ContentState?
    /// 更新排队：正在写入时只记住最新一帧，写完立刻补上
    private var pendingState: LyricActivityAttributes.ContentState?
    private var isUpdating = false

    /// 总开关：Widget 扩展仍保留，但默认不创建活动。
    /// 原因：Live Activity 的 4KB 状态上限 + 系统节流，封面和歌词同步都不稳定。
    static let isEnabled = false

    private init() {}

    func start(title: String, artist: String, artworkData: Data?) {
        guard Self.isEnabled else { return }
        guard #available(iOS 16.1, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }

        let state = LyricActivityAttributes.ContentState(
            title: title,
            artist: artist,
            artworkData: artworkData,
            previous: "",
            current: "正在载入歌词…",
            next: "",
            isPlaying: true
        )

        // 同步创建：异步 Task 会被延迟十几秒，导致歌词更新全部落空
        do {
            activity = try Activity.request(
                attributes: LyricActivityAttributes(title: title, artist: artist),
                contentState: state,
                pushType: nil
            )
            lastState = state
            pendingState = nil
            isUpdating = false
            NSLog("[NekoLive] started id=%@", activity?.id ?? "nil")
        } catch {
            NSLog("[NekoLive] request failed: %@", "\(error)")
            return
        }

        // 清理旧活动放到后台，且不碰刚创建的这个
        let currentID = activity?.id
        Task { @MainActor in
            for old in Activity<LyricActivityAttributes>.activities where old.id != currentID {
                if #available(iOS 16.2, *) {
                    await old.end(nil, dismissalPolicy: .immediate)
                } else {
                    await old.end(dismissalPolicy: .immediate)
                }
            }
        }
    }

    func update(title: String, artist: String, artworkData: Data?, previous: String, current: String, next: String, isPlaying: Bool) {
        guard #available(iOS 16.1, *) else { return }
        guard let activity = activity else {
            NSLog("[NekoLive] update skipped: no activity")
            return
        }

        let state = LyricActivityAttributes.ContentState(
            title: title,
            artist: artist,
            artworkData: artworkData,
            previous: previous,
            current: current,
            next: next,
            isPlaying: isPlaying
        )

        // 内容没变就不打扰系统
        guard state != lastState else { return }
        NSLog("[NekoLive] update -> %@", current)
        lastState = state
        pendingState = state

        guard !isUpdating else { return }
        isUpdating = true
        // 提高优先级，避免后台播放时更新被延后
        Task(priority: .userInitiated) { await drain(activity: activity) }
    }

    /// 串行地把待更新状态写进活动，避免并发 update 丢帧
    private func drain(activity: Activity<LyricActivityAttributes>) async {
        while let state = pendingState {
            pendingState = nil
            await activity.update(using: state)
        }
        isUpdating = false
        NSLog("[NekoLive] drained")
    }

    /// App 启动时清掉旧版本残留的活动，避免显示过期结构
    func endAll() {
        activity = nil
        lastState = nil
        pendingState = nil
        isUpdating = false

        Task {
            for item in Activity<LyricActivityAttributes>.activities {
                if #available(iOS 16.2, *) {
                    await item.end(nil, dismissalPolicy: .immediate)
                } else {
                    await item.end(dismissalPolicy: .immediate)
                }
            }
        }
    }

    func end() {
        guard #available(iOS 16.1, *) else { return }
        guard let activity = activity else { return }
        self.activity = nil
        lastState = nil
        Task {
            if #available(iOS 16.2, *) {
                await activity.end(nil, dismissalPolicy: .immediate)
            } else {
                await activity.end(dismissalPolicy: .immediate)
            }
        }
    }
}
