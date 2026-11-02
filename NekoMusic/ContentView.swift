import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var playerService: AudioPlayerService
    @State private var selectedTab = 0
    @State private var showNowPlaying = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                mainContent

                if showNowPlaying {
                    NowPlayingView(isPresented: $showNowPlaying, containerSize: proxy.size)
                        .environmentObject(playerService)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.move(edge: .bottom))
                        .zIndex(2)
                }
            }
        }
        .animation(.easeInOut(duration: 0.28), value: showNowPlaying)
        .onChange(of: playerService.presentNowPlaying) { value in
            guard value else { return }
            showNowPlaying = true
            playerService.presentNowPlaying = false
        }
        .task(id: authService.isLoggedIn) {
            if authService.isLoggedIn, let token = authService.token {
                NotificationService.shared.startStream(token: token)
            } else {
                NotificationService.shared.stopStream()
            }
        }
    }

    private var mainContent: some View {
        Group {
            if #available(iOS 26.1, *) {
                tabs.tabViewBottomAccessory(isEnabled: playerService.currentMusic != nil) {
                    MiniPlayerAccessory(showNowPlaying: $showNowPlaying)
                }
            } else if #available(iOS 26.0, *) {
                tabs.tabViewBottomAccessory {
                    if playerService.currentMusic != nil {
                        MiniPlayerAccessory(showNowPlaying: $showNowPlaying)
                    }
                }
            } else {
                // iOS 18 及更早：safeAreaInset 会压在系统 tab bar 上，需要手动让出 tab bar 高度
                tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                    if playerService.currentMusic != nil {
                        MiniPlayerBar(showNowPlaying: $showNowPlaying)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 49)
                    }
                }
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house") }
                .tag(0)

            DiscoverView()
                .tabItem { Label("发现", systemImage: "magnifyingglass") }
                .tag(1)

            LibraryView()
                .tabItem { Label("音乐库", systemImage: "music.note.list") }
                .tag(2)

            ProfileView()
                .tabItem { Label("我的", systemImage: "person") }
                .tag(3)
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if playerService.currentMusic != nil {
            MiniPlayerBar(showNowPlaying: $showNowPlaying)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthService.shared)
        .environmentObject(AudioPlayerService.shared)
}
