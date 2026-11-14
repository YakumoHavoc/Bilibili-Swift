import SwiftUI
import AppKit

struct BangumiView: View {
    @EnvironmentObject private var app: AppState
    @State private var items: [BangumiItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasMore = true
    @State private var sort = 0

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 165, maximum: 240), spacing: 16, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "番剧", subtitle: "追番追剧，精彩不停") {
                    PlainIconButton(systemName: "arrow.clockwise", action: {
                        Task { await reload() }
                    }, help: "刷新番剧")
                }
                .padding(.bottom, 12)

                HStack(spacing: 6) {
                    PillTabButton(title: "综合排序", selected: sort == 0) {
                        sort = 0
                        Task { await reload() }
                    }
                    PillTabButton(title: "播放最多", selected: sort == 2) {
                        sort = 2
                        Task { await reload() }
                    }
                    PillTabButton(title: "最新上线", selected: sort == 4) {
                        sort = 4
                        Task { await reload() }
                    }
                }
                .padding(.bottom, 14)

                content
            }
            .padding(Metrics.contentPadding)
        }
        .background(Palette.bg)
        .task { if items.isEmpty { await reload() } }
        .onChange(of: app.refreshToken) { _, _ in Task { await reload() } }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            LoadingStateView()
        } else if let errorMessage, items.isEmpty {
            ErrorStateView(message: errorMessage) { Task { await reload() } }
        } else if items.isEmpty {
            Text("暂无番剧")
                .font(.ui(13))
                .foregroundStyle(Palette.text3)
                .frame(maxWidth: .infinity)
                .padding(80)
        } else {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(items) { item in
                    BangumiCardView(item: item) {
                        open(item)
                    }
                }
            }

            if isLoadingMore {
                ProgressView().controlSize(.small).padding(18)
            } else if hasMore {
                Color.clear.frame(height: 2).onAppear { Task { await loadMore() } }
            }
        }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        page = 1
        do {
            let data = try await BiliAPI.bangumi(seasonType: 1, sort: sort, page: 1)
            items = (data.list ?? []).map { BangumiItem(dto: $0) }
            hasMore = data.has_next == 1
            page = 2
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        do {
            let data = try await BiliAPI.bangumi(seasonType: 1, sort: sort, page: page)
            items += (data.list ?? []).map { BangumiItem(dto: $0) }
            hasMore = data.has_next == 1
            page += 1
        } catch {
            hasMore = false
        }
        isLoadingMore = false
    }

    private func open(_ item: BangumiItem) {
        if let ep = item.epID {
            PlayerWindowController.shared.openEpisode(epID: ep, title: item.title, app: app)
        } else if let url = URL(string: item.link) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 影视

enum CinemaTab: String, CaseIterable, Identifiable {
    case movie
    case tv
    case documentary
    case variety

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movie: return "电影"
        case .tv: return "电视剧"
        case .documentary: return "纪录片"
        case .variety: return "综艺"
        }
    }

    var seasonType: Int {
        switch self {
        case .movie: return 2
        case .tv: return 5
        case .documentary: return 3
        case .variety: return 7
        }
    }
}

struct CinemaView: View {
    @EnvironmentObject private var app: AppState
    @State private var tab: CinemaTab = .movie
    @State private var items: [BangumiItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasMore = true

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 165, maximum: 240), spacing: 16, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "影视", subtitle: "电影 · 电视剧 · 纪录片 · 综艺") {
                    PlainIconButton(systemName: "arrow.clockwise", action: {
                        Task { await reload() }
                    }, help: "刷新影视")
                }
                .padding(.bottom, 12)

                HStack(spacing: 6) {
                    ForEach(CinemaTab.allCases) { item in
                        PillTabButton(title: item.title, selected: tab == item) {
                            tab = item
                            Task { await reload() }
                        }
                    }
                }
                .padding(.bottom, 14)

                if isLoading && items.isEmpty {
                    LoadingStateView()
                } else if let errorMessage, items.isEmpty {
                    ErrorStateView(message: errorMessage) { Task { await reload() } }
                } else if items.isEmpty {
                    Text("暂无内容")
                        .font(.ui(13))
                        .foregroundStyle(Palette.text3)
                        .frame(maxWidth: .infinity)
                        .padding(80)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(items) { item in
                            BangumiCardView(item: item) {
                                open(item)
                            }
                        }
                    }

                    if isLoadingMore {
                        ProgressView().controlSize(.small).padding(18)
                    } else if hasMore {
                        Color.clear.frame(height: 2).onAppear { Task { await loadMore() } }
                    }
                }
            }
            .padding(Metrics.contentPadding)
        }
        .background(Palette.bg)
        .task { if items.isEmpty { await reload() } }
        .onChange(of: app.refreshToken) { _, _ in Task { await reload() } }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        page = 1
        do {
            let data = try await BiliAPI.bangumi(seasonType: tab.seasonType, page: 1)
            items = (data.list ?? []).map { BangumiItem(dto: $0) }
            hasMore = data.has_next == 1
            page = 2
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        do {
            let data = try await BiliAPI.bangumi(seasonType: tab.seasonType, page: page)
            items += (data.list ?? []).map { BangumiItem(dto: $0) }
            hasMore = data.has_next == 1
            page += 1
        } catch {
            hasMore = false
        }
        isLoadingMore = false
    }

    private func open(_ item: BangumiItem) {
        if let ep = item.epID {
            PlayerWindowController.shared.openEpisode(epID: ep, title: item.title, app: app)
        } else if let url = URL(string: item.link) {
            NSWorkspace.shared.open(url)
        }
    }
}
