import SwiftUI

struct SidebarItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let page: Page
}

struct SidebarView: View {
    @EnvironmentObject private var app: AppState

    private let items: [SidebarItem] = [
        .init(id: "home", title: "首页", icon: "house.fill", page: .home),
        .init(id: "popular", title: "热门", icon: "flame.fill", page: .popular),
        .init(id: "live", title: "直播", icon: "dot.radiowaves.left.and.right", page: .live),
        .init(id: "bangumi", title: "番剧", icon: "play.tv.fill", page: .bangumi),
        .init(id: "cinema", title: "影视", icon: "film.fill", page: .cinema),
        .init(id: "dynamic", title: "动态", icon: "bubble.left.and.bubble.right.fill", page: .dynamic),
        .init(id: "favorites", title: "收藏", icon: "star.fill", page: .favorites),
        .init(id: "downloads", title: "下载", icon: "arrow.down.circle.fill", page: .downloads),
        .init(id: "recordings", title: "录制", icon: "record.circle", page: .recordings),
        .init(id: "mine", title: "我的", icon: "person.crop.circle.fill", page: .mine(.history))
    ]

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 40)
                .background(WindowDragArea())

            VStack(spacing: 2) {
                ForEach(items) { item in
                    itemButton(item)
                }
            }
            .padding(.top, 4)

            Spacer()

            VStack(spacing: 2) {
                itemButton(SidebarItem(id: "settings", title: "设置", icon: "gearshape.fill", page: .settings))
                profileButton
            }
            .padding(.bottom, 14)
        }
        .frame(width: Metrics.sidebarWidth)
        .background(Palette.navBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Palette.line)
                .frame(width: 1)
        }
    }

    private func itemButton(_ item: SidebarItem) -> some View {
        let selected = isSelected(item.page)
        return Button {
            app.navigate(item.page)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? Palette.pink : Palette.text2)
                Text(item.title)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Palette.pink : Palette.text2)
            }
            .frame(width: 56, height: 52)
            .background(selected ? Palette.pink.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    @ViewBuilder
    private var profileButton: some View {
        Button {
            if app.user == nil {
                app.showLogin = true
            } else {
                app.navigate(.space(app.user?.mid ?? 0))
            }
        } label: {
            Group {
                if let user = app.user, !user.face.isEmpty {
                    AvatarView(url: ImageURL.thumb(user.face, width: 80, height: 80), size: 28)
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.text2)
                }
            }
            .frame(width: 56, height: 44)
        }
        .buttonStyle(.plain)
        .help(app.user == nil ? "扫码登录" : "个人空间")
    }

    private func isSelected(_ page: Page) -> Bool {
        switch page {
        case .home: return app.page == .home
        case .popular: return app.page == .popular
        case .live: return app.page == .live
        case .bangumi: return app.page == .bangumi
        case .cinema: return app.page == .cinema
        case .dynamic: return app.page == .dynamic
        case .favorites: return app.page == .favorites
        case .downloads: return app.page == .downloads
        case .recordings: return app.page == .recordings
        case .settings: return app.page == .settings
        case .mine:
            if case .mine = app.page { return true }
            if case .space = app.page { return true }
            return false
        default:
            return false
        }
    }
}
