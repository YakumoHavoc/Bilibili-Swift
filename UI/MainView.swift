import SwiftUI

struct MainView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView()
                VStack(spacing: 0) {
                    TopBarView()
                    Divider().overlay(Palette.line)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.bg)
                }
            }
            .background(Palette.bg)

            if let toast = app.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.ui(13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Color.black.opacity(0.78))
                        .clipShape(Capsule())
                        .padding(.bottom, 32)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(app.themeMode.colorScheme)
        .background(MainWindowBinder())
        .sheet(isPresented: $app.showLogin) {
            LoginSheet()
                .environmentObject(app)
        }
        .onAppear {
            app.bootstrap()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.page {
        case .home:
            HomeView()
        case .popular:
            PopularView()
        case .ranking:
            RankingView()
        case .live:
            LiveView()
        case .bangumi:
            BangumiView()
        case .cinema:
            CinemaView()
        case .dynamic:
            DynamicView()
        case .messages:
            MessagesView()
        case .favorites:
            FavoritesView()
        case .downloads:
            DownloadsView()
        case .recordings:
            RecordingsView()
        case .mine(let tab):
            MineView(initialTab: tab)
        case .settings:
            SettingsView()
        case .search(let keyword):
            SearchView(keyword: keyword)
        case .space(let mid):
            SpaceView(mid: mid)
        }
    }
}
