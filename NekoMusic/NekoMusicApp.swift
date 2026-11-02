import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .allButUpsideDown
    }
}

@main
struct NekoMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var authService = AuthService.shared
    @StateObject private var playerService = AudioPlayerService.shared
    @StateObject private var appearance = AppearanceSettings.shared
    @StateObject private var serverConfig = ServerConfig.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if serverConfig.isReady {
                    ContentView()
                        .environmentObject(authService)
                        .environmentObject(playerService)
                        .environmentObject(appearance)
                } else {
                    // 未同意声明、或没选来源之前，不进入主界面
                    OnboardingView(config: serverConfig)
                }
            }
            .tint(appearance.tintColor)
            .preferredColorScheme(appearance.colorScheme)
        }
    }
}
