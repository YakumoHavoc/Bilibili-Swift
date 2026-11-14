import SwiftUI

struct MineView: View {
    @EnvironmentObject private var app: AppState
    let initialTab: MineTab

    @State private var tab: MineTab
    @State private var historyItems: [HistoryCard] = []
    @State private var watchLater: [VideoCard] = []
    @State private var favoriteReloadID = 0
    @State private var historyCursor: HistoryCursor?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    init(initialTab: MineTab) {
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        Group {
            if !BiliClient.shared.isLoggedIn {
                LoginPromptView(title: "登录后查看历史记录、收藏和稍后再看") {
                    app.showLogin = true
                }
                .background(Palette.bg)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        PageHeader(title: "我的", subtitle: app.user?.name ?? "") {
                            PlainIconButton(systemName: "arrow.clockwise", action: {
                                Task { await refreshCurrentTab() }
                            }, help: "刷新")
                        }
                        .padding(.bottom, 2)

                        HStack(spacing: 6) {
                            ForEach(MineTab.allCases) { item in
                                PillTabButton(title: item.title, selected: tab == item) {
                                    tab = item
                                }
                            }
                        }
                        .padding(.bottom, 6)

                        content
                    }
                    .padding(Metrics.contentPadding)
                }
                .background(Palette.bg)
            }
        }
        .task(id: tab) { await loadTab(tab) }
        .onChange(of: app.user?.mid) { _, _ in
            if BiliClient.shared.isLoggedIn {
                Task { await refreshCurrentTab() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if tab == .favorite {
            favoriteContent
        } else if isLoading {
            LoadingStateView()
        } else if let errorMessage {
            ErrorStateView(message: errorMessage) { Task { await refreshCurrentTab() } }
        } else {
            switch tab {
            case .history:
                historyContent
            case .watchLater:
                watchLaterContent
            case .favorite:
                EmptyView()
            }
        }
    }

    // MARK: - 历史

    @ViewBuilder
    private var historyContent: some View {
        if historyItems.isEmpty {
            emptyText("暂无观看历史")
        } else {
            LazyVStack(spacing: 4) {
                ForEach(historyItems) { item in
                    historyRow(item)
                }
            }
            if isLoadingMore {
                ProgressView().controlSize(.small).padding(18)
            } else if historyCursor != nil {
                Color.clear.frame(height: 2).onAppear { Task { await loadMoreHistory() } }
            }
        }
    }

    private func historyRow(_ item: HistoryCard) -> some View {
        let card = VideoCard(id: item.bvid ?? "av\(item.id)",
                             bvid: item.bvid,
                             cid: item.cid,
                             title: item.title,
                             cover: item.cover,
                             duration: item.duration,
                             upName: item.upName,
                             upMid: item.upMid,
                             views: 0,
                             pubdate: item.viewAt)
        return HStack(spacing: 14) {
            RemoteImage(url: ImageURL.thumb(item.cover, width: 320, height: 200))
                .frame(width: 168, height: 105)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .overlay(alignment: .bottom) {
                    GeometryReader { proxy in
                        let ratio = item.duration > 0 ? min(1, Double(item.progress) / Double(item.duration)) : 0
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.3))
                            Rectangle().fill(Palette.pink).frame(width: proxy.size.width * ratio)
                        }
                        .frame(height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    DurationBadge(seconds: item.duration).padding(5)
                }

            VStack(alignment: .leading, spacing: 7) {
                Text(item.title)
                    .font(.ui(14, weight: .medium))
                    .foregroundStyle(Palette.text1)
                    .lineLimit(2)
                Text(item.upName)
                    .font(.ui(12))
                    .foregroundStyle(Palette.text3)
                Spacer(minLength: 0)
                Text("\(Fmt.relativeDate(item.viewAt)) 看过 · \(Fmt.duration(item.progress))")
                    .font(.ui(11))
                    .foregroundStyle(Palette.text3)
            }
            .padding(.vertical, 2)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(height: 121)
        .contentShape(Rectangle())
        .onTapGesture { app.play(video: card) }
        .contextMenu {
            Button("播放") { app.play(video: card) }
            if let mid = item.upMid {
                Button("UP 主空间") { app.navigate(.space(mid)) }
            }
        }
    }

    // MARK: - 收藏

    @ViewBuilder
    private var favoriteContent: some View {
        FavoriteBrowser(reloadID: favoriteReloadID)
    }

    // MARK: - 稍后再看

    @ViewBuilder
    private var watchLaterContent: some View {
        if watchLater.isEmpty {
            emptyText("暂无稍后再看的视频")
        } else {
            LazyVStack(spacing: 4) {
                ForEach(watchLater) { video in
                    VideoRowView(video: video,
                                 onOpen: { app.play(video: video) },
                                 onOpenUp: {
                                     if let mid = video.upMid { app.navigate(.space(mid)) }
                                 })
                }
            }
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.ui(13))
            .foregroundStyle(Palette.text3)
            .frame(maxWidth: .infinity)
            .padding(60)
    }

    // MARK: - 加载

    private func loadTab(_ target: MineTab) async {
        guard BiliClient.shared.isLoggedIn else { return }
        switch target {
        case .history:
            if historyItems.isEmpty { await loadHistory(reset: true) }
        case .favorite:
            // 收藏内容由 FavoriteBrowser 自行加载。
            break
        case .watchLater:
            // 每次进入都重新拉取，保证刚添加的视频能出现在列表里。
            await loadWatchLater()
        }
    }

    private func refreshCurrentTab() async {
        switch tab {
        case .history: await loadHistory(reset: true)
        case .favorite: favoriteReloadID += 1
        case .watchLater: await loadWatchLater()
        }
    }

    private func loadHistory(reset: Bool) async {
        isLoading = reset
        errorMessage = nil
        if reset {
            historyItems = []
            historyCursor = nil
        }
        do {
            let data = try await BiliAPI.history()
            let mapped = (data.list ?? []).compactMap { item -> HistoryCard? in
                guard let history = item.history, let bvid = history.bvid else { return nil }
                return HistoryCard(id: bvid,
                                   bvid: bvid,
                                   cid: history.cid,
                                   title: item.title ?? item.long_title ?? "",
                                   cover: ImageURL.fix(item.cover),
                                   upName: item.author_name ?? "",
                                   upMid: item.author_mid,
                                   progress: item.progress ?? 0,
                                   duration: item.duration ?? 0,
                                   viewAt: item.view_at ?? 0)
            }
            historyItems = mapped
            historyCursor = data.cursor
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMoreHistory() async {
        guard !isLoadingMore, let cursor = historyCursor else { return }
        isLoadingMore = true
        do {
            let data = try await BiliAPI.history(max: cursor.max, viewAt: cursor.view_at)
            let mapped = (data.list ?? []).compactMap { item -> HistoryCard? in
                guard let history = item.history, let bvid = history.bvid else { return nil }
                return HistoryCard(id: bvid,
                                   bvid: bvid,
                                   cid: history.cid,
                                   title: item.title ?? item.long_title ?? "",
                                   cover: ImageURL.fix(item.cover),
                                   upName: item.author_name ?? "",
                                   upMid: item.author_mid,
                                   progress: item.progress ?? 0,
                                   duration: item.duration ?? 0,
                                   viewAt: item.view_at ?? 0)
            }
            historyItems += mapped
            historyCursor = data.cursor
            if mapped.isEmpty { historyCursor = nil }
        } catch {
            historyCursor = nil
        }
        isLoadingMore = false
    }

    private func loadWatchLater() async {
        isLoading = true
        errorMessage = nil
        do {
            let data = try await BiliAPI.watchLater()
            watchLater = (data.list ?? []).map { item in
                VideoCard(id: item.bvid ?? "av\(item.aid ?? 0)",
                          bvid: item.bvid,
                          aid: item.aid,
                          cid: item.cid,
                          title: item.title ?? "",
                          cover: ImageURL.fix(item.pic),
                          duration: item.duration ?? 0,
                          upName: item.owner?.name ?? "",
                          upFace: ImageURL.fix(item.owner?.face),
                          upMid: item.owner?.mid,
                          views: item.stat?.view ?? 0,
                          danmaku: item.stat?.danmaku ?? 0,
                          pubdate: item.add_at ?? 0)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
