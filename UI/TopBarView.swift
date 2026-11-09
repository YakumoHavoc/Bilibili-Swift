import SwiftUI

struct TopBarView: View {
    @EnvironmentObject private var app: AppState
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var showsBack: Bool {
        switch app.page {
        case .search, .space: return true
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if showsBack {
                PlainIconButton(systemName: "chevron.left", action: { app.goBack() }, help: "返回")
            }

            HStack(spacing: 6) {
                Text("bili")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 22)
                    .background(
                        LinearGradient(colors: [Palette.pink, Color(hex: 0xF25C8A)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("哔哩哔哩")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text1)
            }
            .padding(.leading, 6)

            searchField

            Spacer(minLength: 8)

            PlainIconButton(systemName: themeIcon, action: cycleTheme, help: "切换主题")

            if let user = app.user {
                // 与左下角一致的小圆形头像：Menu 的 label 会按图片原始尺寸渲染，
                // 无法保持圆形，因此改用 Button + 右键菜单。
                Button {
                    app.navigate(.space(user.mid))
                } label: {
                    AvatarView(url: ImageURL.thumb(user.face, width: 80, height: 80), size: 28)
                }
                .buttonStyle(.plain)
                .help(user.name)
                .contextMenu {
                    Button("个人空间") { app.navigate(.space(user.mid)) }
                    Button("我的收藏") { app.navigate(.mine(.favorite)) }
                    Button("历史记录") { app.navigate(.mine(.history)) }
                    Divider()
                    Button("退出登录") { app.logout() }
                }
            } else {
                Button {
                    app.showLogin = true
                } label: {
                    Text("登录")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Palette.pink)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Metrics.topBarHeight)
        .background(WindowDragArea())
        .background(Palette.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.line).frame(height: 1)
        }
        .onAppear { syncQuery() }
        .onChange(of: app.page) { _, _ in syncQuery() }
        .onChange(of: app.refreshToken) { _, _ in
            if case .search(let keyword) = app.page {
                app.navigate(.search(keyword), pushBack: false)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Palette.text3)
            TextField("搜索视频、UP主", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text1)
                .focused($searchFocused)
                .onSubmit {
                    app.search(query)
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 320, height: 30)
        .background(Palette.bgRegular)
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(searchFocused ? Palette.pink.opacity(0.6) : Color.clear, lineWidth: 1)
        }
    }

    private var themeIcon: String {
        switch app.themeMode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    private func cycleTheme() {
        switch app.themeMode {
        case .system: app.themeMode = .light
        case .light: app.themeMode = .dark
        case .dark: app.themeMode = .system
        }
    }

    private func syncQuery() {
        if case .search(let keyword) = app.page {
            query = keyword
        } else if case .space = app.page {
            // 保留上一次搜索词
        } else {
            query = ""
        }
    }
}
