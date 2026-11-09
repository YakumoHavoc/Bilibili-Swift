import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var app: AppState

    /// 关注 Tab 使用 -1 作为标识，排在最前面并默认选中。
    private let followingTab = -1

    @State private var areas: [LiveParentArea] = []
    @State private var selectedParent = -1
    @State private var rooms: [LiveRoom] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var canLoadMore = true

    private var isFollowingTab: Bool { selectedParent == followingTab }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 18, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "直播", subtitle: "正在直播的精彩内容") {
                    PlainIconButton(systemName: "arrow.clockwise", action: {
                        Task { await reload() }
                    }, help: "刷新直播")
                }
                .padding(.bottom, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        PillTabButton(title: "关注", selected: isFollowingTab) {
                            selectedParent = followingTab
                            Task { await reload() }
                        }
                        ForEach(areas) { area in
                            PillTabButton(title: area.name, selected: selectedParent == area.id) {
                                selectedParent = area.id
                                Task { await reload() }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .padding(.bottom, 12)

                if isLoading && rooms.isEmpty {
                    LoadingStateView()
                } else if let errorMessage, rooms.isEmpty {
                    ErrorStateView(message: errorMessage) { Task { await reload() } }
                } else if rooms.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(rooms) { room in
                            LiveCardView(room: room) {
                                PlayerWindowController.shared.openLive(room: room, app: app)
                            }
                        }
                    }

                    if isLoadingMore {
                        ProgressView().controlSize(.small).padding(18)
                    } else if canLoadMore {
                        Color.clear.frame(height: 2).onAppear {
                            Task { await loadMore() }
                        }
                    }
                }
            }
            .padding(Metrics.contentPadding)
        }
        .background(Palette.bg)
        .task {
            if areas.isEmpty { await loadAreas() }
            if rooms.isEmpty { await reload() }
        }
        .onChange(of: app.refreshToken) { _, _ in Task { await reload() } }
        .onChange(of: app.user?.mid) { _, _ in Task { await reload() } }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(isFollowingTab
                 ? (BiliClient.shared.isLoggedIn ? "关注的主播暂未开播" : "登录后查看关注主播的直播")
                 : "暂无直播内容")
                .font(.system(size: 13))
                .foregroundStyle(Palette.text3)

            if isFollowingTab, !BiliClient.shared.isLoggedIn {
                Button {
                    app.showLogin = true
                } label: {
                    Text("登录")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .background(Palette.blue)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func loadAreas() async {
        do {
            areas = try await BiliAPI.liveAreas()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        page = 1

        if isFollowingTab {
            guard BiliClient.shared.isLoggedIn else {
                rooms = []
                canLoadMore = false
                isLoading = false
                return
            }
            do {
                let data = try await BiliAPI.followingLiveFeed()
                rooms = (data.list ?? []).map { FollowingLiveRoom(dto: $0).asLiveRoom }
                canLoadMore = false
            } catch {
                rooms = []
                errorMessage = error.localizedDescription
            }
            isLoading = false
            return
        }

        guard selectedParent > 0 else {
            isLoading = false
            return
        }
        do {
            rooms = try await BiliAPI.liveRooms(parentAreaID: selectedParent, page: 1)
            page = 2
            canLoadMore = rooms.count >= 20
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading, !isLoadingMore, canLoadMore, selectedParent > 0 else { return }
        isLoadingMore = true
        do {
            let items = try await BiliAPI.liveRooms(parentAreaID: selectedParent, page: page)
            rooms += items
            page += 1
            canLoadMore = !items.isEmpty
        } catch {
            canLoadMore = false
        }
        isLoadingMore = false
    }
}
