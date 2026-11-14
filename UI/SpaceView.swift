import SwiftUI
import AppKit

/// UP 主空间的三个页签。
private enum SpaceTab: String, CaseIterable, Identifiable {
    case home
    case dynamic
    case collection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "主页"
        case .dynamic: return "动态"
        case .collection: return "合集和系列"
        }
    }
}

struct SpaceView: View {
    @EnvironmentObject private var app: AppState
    let mid: Int

    @State private var tab: SpaceTab = .home

    // 主页（投稿）
    @State private var info: SpaceInfoData?
    @State private var videos: [VideoCard] = []
    @State private var page = 1
    @State private var total = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    // 动态
    @State private var dynamics: [DynamicItem] = []
    @State private var dynamicOffset: String?
    @State private var hasMoreDynamics = true
    @State private var isLoadingDynamics = false
    @State private var isLoadingMoreDynamics = false
    @State private var dynamicError: String?
    @State private var commentTarget: DynamicItem?
    @State private var imageViewer: ImageViewerPayload?
    @State private var forwardTarget: DynamicDetailTarget?

    // 合集和系列
    @State private var collections: [SpaceCollection] = []
    @State private var collectionPage = 1
    @State private var collectionTotal = 0
    @State private var isLoadingCollections = false
    @State private var isLoadingMoreCollections = false
    @State private var collectionError: String?
    @State private var collectionTarget: SpaceCollection?

    private var hasMore: Bool { videos.count < total }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let info {
                    header(info)
                }

                tabBar

                switch tab {
                case .home:
                    homeContent
                case .dynamic:
                    dynamicContent
                case .collection:
                    collectionContent
                }
            }
            .padding(Metrics.contentPadding)
        }
        .background(Palette.bg)
        .task(id: mid) {
            reset()
            await reload()
        }
        .onChange(of: app.refreshToken) { _, _ in Task { await reload() } }
        .sheet(item: $commentTarget) { item in
            DynamicCommentsSheet(dynamic: item)
        }
        .sheet(item: $imageViewer) { payload in
            ImageViewerSheet(payload: payload)
        }
        .sheet(item: $forwardTarget) { target in
            DynamicDetailSheet(target: target)
        }
        .sheet(item: $collectionTarget) { collection in
            SpaceCollectionSheet(mid: mid,
                                 collection: collection,
                                 upName: info?.name ?? "")
        }
    }

    // MARK: - 头部与页签

    private func header(_ info: SpaceInfoData) -> some View {
        HStack(alignment: .center, spacing: 18) {
            AvatarView(url: ImageURL.thumb(info.face, width: 200, height: 200), size: 84)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(info.name ?? "UP主")
                        .font(.ui(20, weight: .semibold))
                        .foregroundStyle(Palette.text1)
                    Text("Lv\(info.level ?? 0)")
                        .font(.ui(10))
                        .foregroundStyle(Palette.pink)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Palette.pink.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(info.sign ?? "")
                    .font(.ui(12))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(2)
                HStack(spacing: 16) {
                    Text("\(Fmt.count(info.fans ?? 0)) 粉丝")
                    Text("\(Fmt.count(total)) 投稿")
                    Text("\(Fmt.count(info.attention ?? 0)) 关注")
                }
                .font(.ui(11))
                .foregroundStyle(Palette.text3)
            }
            Spacer()
            if let url = URL(string: "https://space.bilibili.com/\(mid)") {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("在浏览器打开")
                        .font(.ui(12))
                        .foregroundStyle(Palette.text2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.bgRegular)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(Palette.bgThin)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var tabBar: some View {
        HStack(spacing: 26) {
            tabButton(.home)
            tabButton(.dynamic)
            tabButton(.collection, count: collectionTotal)
            Spacer()
        }
    }

    private func tabButton(_ target: SpaceTab, count: Int? = nil) -> some View {
        let selected = tab == target
        return Button {
            guard tab != target else { return }
            tab = target
            if target == .dynamic { Task { await loadDynamicsIfNeeded() } }
            if target == .collection { Task { await loadCollectionsIfNeeded() } }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: icon(for: target))
                        .font(.ui(11, weight: .semibold))
                    Text(target.title)
                        .font(.ui(14, weight: selected ? .semibold : .regular))
                    if let count, count > 0 {
                        Text(Fmt.count(count))
                            .font(.ui(11))
                    }
                }
                .foregroundStyle(selected ? Palette.blue : Palette.text2)
                Rectangle()
                    .fill(selected ? Palette.blue : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(for tab: SpaceTab) -> String {
        switch tab {
        case .home: return "house"
        case .dynamic: return "bubble.left.and.bubble.right"
        case .collection: return "rectangle.stack"
        }
    }

    // MARK: - 主页

    @ViewBuilder
    private var homeContent: some View {
        if isLoading && videos.isEmpty {
            LoadingStateView()
        } else if let errorMessage, videos.isEmpty {
            ErrorStateView(message: errorMessage) { Task { await reload() } }
        } else {
            Text("TA 的投稿")
                .font(.ui(16, weight: .semibold))
                .foregroundStyle(Palette.text1)

            VideoGrid(videos: videos, onOpen: { video in
                app.play(video: video)
            })

            if isLoadingMore {
                ProgressView().controlSize(.small).padding(18)
            } else if hasMore {
                Color.clear.frame(height: 2).onAppear { Task { await loadMore() } }
            }
        }
    }

    // MARK: - 动态

    @ViewBuilder
    private var dynamicContent: some View {
        if isLoadingDynamics && dynamics.isEmpty {
            LoadingStateView()
        } else if let dynamicError, dynamics.isEmpty {
            ErrorStateView(message: dynamicError) { Task { await loadDynamics() } }
        } else if dynamics.isEmpty {
            Text("TA 还没有发布过动态")
                .font(.ui(12))
                .foregroundStyle(Palette.text3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            ForEach(dynamics) { item in
                DynamicCardView(item: item) { bvid, title in
                    app.play(video: VideoCard(id: bvid, bvid: bvid, title: title,
                                              cover: "", duration: 0))
                } onOpenSpace: { userMid in
                    guard userMid != mid else { return }
                    app.navigate(.space(userMid))
                } onOpenComments: {
                    commentTarget = item
                } onOpenImages: { urls, index in
                    imageViewer = ImageViewerPayload(images: urls, index: index)
                } onOpenForward: { item in
                    forwardTarget = DynamicDetailTarget(item: item)
                } onOpenLive: { room in
                    PlayerWindowController.shared.openLive(room: room, app: app)
                }

                Rectangle()
                    .fill(Palette.line)
                    .frame(height: 1)
            }

            if isLoadingMoreDynamics {
                ProgressView().controlSize(.small).padding(18)
                    .frame(maxWidth: .infinity)
            } else if hasMoreDynamics {
                Color.clear
                    .frame(height: 2)
                    .onAppear { Task { await loadMoreDynamics() } }
            } else {
                Text("没有更多动态了")
                    .font(.ui(12))
                    .foregroundStyle(Palette.text3)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            }
        }
    }

    // MARK: - 合集和系列

    @ViewBuilder
    private var collectionContent: some View {
        if isLoadingCollections && collections.isEmpty {
            LoadingStateView()
        } else if let collectionError, collections.isEmpty {
            ErrorStateView(message: collectionError) { Task { await loadCollections() } }
        } else if collections.isEmpty {
            Text("TA 还没有创建合集或系列")
                .font(.ui(12))
                .foregroundStyle(Palette.text3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360),
                                         spacing: 18, alignment: .top)],
                      spacing: 22) {
                ForEach(collections) { collection in
                    collectionCard(collection)
                }
            }

            if isLoadingMoreCollections {
                ProgressView().controlSize(.small).padding(18)
                    .frame(maxWidth: .infinity)
            } else if collections.count < collectionTotal {
                Color.clear
                    .frame(height: 2)
                    .onAppear { Task { await loadMoreCollections() } }
            }
        }
    }

    private func collectionCard(_ collection: SpaceCollection) -> some View {
        Button {
            collectionTarget = collection
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay {
                        RemoteImage(url: ImageURL.thumb(collection.cover))
                            .overlay(alignment: .topLeading) {
                                Text(collection.isSeason ? "合集" : "系列")
                                    .font(.ui(9, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Palette.blue.opacity(0.9))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .padding(6)
                            }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))

                Text(collection.title)
                    .font(.ui(14, weight: .medium))
                    .foregroundStyle(Palette.text1)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(collection.count) 个视频")
                    .font(.ui(11))
                    .foregroundStyle(Palette.text3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看合集")
    }

    // MARK: - 数据

    private func reset() {
        tab = .home
        info = nil
        videos = []
        total = 0
        page = 1
        errorMessage = nil
        dynamics = []
        dynamicOffset = nil
        hasMoreDynamics = true
        dynamicError = nil
        collections = []
        collectionPage = 1
        collectionTotal = 0
        collectionError = nil
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        do {
            async let infoTask = BiliAPI.spaceInfo(mid: mid)
            async let videoTask = BiliAPI.spaceVideos(mid: mid, page: 1)
            info = try await infoTask
            let data = try await videoTask
            videos = (data.list?.vlist ?? []).map { map($0, name: info?.name ?? "") }
            total = data.page?.count ?? videos.count
            page = 2

            // 合集数量只用于页签计数，失败不影响主页内容。
            let collectionData = try? await BiliAPI.spaceCollections(mid: mid, page: 1)
            if let lists = collectionData?.items_lists {
                collections = (lists.seasons_list ?? []) + (lists.series_list ?? [])
                collectionTotal = lists.page?.total ?? collections.count
                collectionPage = 2
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        do {
            let data = try await BiliAPI.spaceVideos(mid: mid, page: page)
            videos += (data.list?.vlist ?? []).map { map($0, name: info?.name ?? "") }
            total = data.page?.count ?? total
            page += 1
        } catch {
            total = videos.count
        }
        isLoadingMore = false
    }

    private func loadDynamicsIfNeeded() async {
        guard dynamics.isEmpty, !isLoadingDynamics else { return }
        await loadDynamics()
    }

    private func loadDynamics() async {
        guard !isLoadingDynamics else { return }
        isLoadingDynamics = true
        dynamicError = nil
        do {
            let data = try await BiliAPI.spaceDynamics(mid: mid)
            dynamics = data.items ?? []
            dynamicOffset = data.offset
            hasMoreDynamics = data.has_more ?? false
        } catch {
            dynamicError = error.localizedDescription
        }
        isLoadingDynamics = false
    }

    private func loadMoreDynamics() async {
        guard !isLoadingMoreDynamics, hasMoreDynamics, let offset = dynamicOffset else { return }
        isLoadingMoreDynamics = true
        do {
            let data = try await BiliAPI.spaceDynamics(mid: mid, offset: offset)
            dynamics += data.items ?? []
            dynamicOffset = data.offset
            hasMoreDynamics = data.has_more ?? false
        } catch {
            hasMoreDynamics = false
        }
        isLoadingMoreDynamics = false
    }

    private func loadCollectionsIfNeeded() async {
        guard collections.isEmpty, !isLoadingCollections else { return }
        await loadCollections()
    }

    private func loadCollections() async {
        guard !isLoadingCollections else { return }
        isLoadingCollections = true
        collectionError = nil
        do {
            let data = try await BiliAPI.spaceCollections(mid: mid, page: 1)
            let lists = data.items_lists
            collections = (lists?.seasons_list ?? []) + (lists?.series_list ?? [])
            collectionTotal = lists?.page?.total ?? collections.count
            collectionPage = 2
        } catch {
            collectionError = error.localizedDescription
        }
        isLoadingCollections = false
    }

    private func loadMoreCollections() async {
        guard !isLoadingMoreCollections, collections.count < collectionTotal else { return }
        isLoadingMoreCollections = true
        do {
            let data = try await BiliAPI.spaceCollections(mid: mid, page: collectionPage)
            let lists = data.items_lists
            collections += (lists?.seasons_list ?? []) + (lists?.series_list ?? [])
            collectionTotal = lists?.page?.total ?? collectionTotal
            collectionPage += 1
        } catch {
            collectionTotal = collections.count
        }
        isLoadingMoreCollections = false
    }

    private func map(_ dto: SpaceVideoDTO, name: String) -> VideoCard {
        VideoCard(id: dto.bvid ?? "av\(dto.aid ?? 0)",
                  bvid: dto.bvid,
                  aid: dto.aid,
                  title: dto.title ?? "",
                  cover: ImageURL.fix(dto.pic),
                  duration: Fmt.durationString(dto.length),
                  upName: dto.author ?? name,
                  upMid: dto.mid ?? mid,
                  views: dto.play ?? 0,
                  danmaku: dto.comment ?? 0,
                  pubdate: dto.created ?? 0)
    }
}

// MARK: - 合集 / 系列详情

/// 合集或系列内的视频列表，以弹窗形式展示。
struct SpaceCollectionSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    let mid: Int
    let collection: SpaceCollection
    let upName: String

    @State private var videos: [VideoCard] = []
    @State private var page = 1
    @State private var total = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    private var hasMore: Bool { videos.count < total }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(collection.title)
                    .font(.ui(15, weight: .semibold))
                    .foregroundStyle(Palette.text1)
                    .lineLimit(1)
                Text("\(Fmt.count(total)) 个视频")
                    .font(.ui(11))
                    .foregroundStyle(Palette.text3)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.ui(12, weight: .medium))
                        .foregroundStyle(Palette.text3)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Rectangle()
                .fill(Palette.line)
                .frame(height: 1)

            ScrollView {
                if isLoading && videos.isEmpty {
                    LoadingStateView()
                        .padding(.vertical, 60)
                } else if let errorMessage, videos.isEmpty {
                    ErrorStateView(message: errorMessage) { Task { await load(reset: true) } }
                        .padding(.vertical, 40)
                } else if videos.isEmpty {
                    Text("该合集还没有视频")
                        .font(.ui(12))
                        .foregroundStyle(Palette.text3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    VStack(spacing: 14) {
                        VideoGrid(videos: videos, onOpen: { video in
                            app.play(video: video)
                        })

                        if isLoadingMore {
                            ProgressView().controlSize(.small).padding(14)
                        } else if hasMore {
                            Color.clear
                                .frame(height: 2)
                                .onAppear { Task { await load(reset: false) } }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 780, height: 660)
        .background(Palette.bg)
        .task { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        if reset {
            isLoading = true
            errorMessage = nil
            page = 1
            videos = []
        } else {
            guard !isLoadingMore, hasMore else { return }
            isLoadingMore = true
        }

        do {
            let data: SpaceArchiveData
            if let seasonID = collection.meta?.season_id {
                data = try await BiliAPI.spaceSeasonArchives(mid: mid,
                                                             seasonID: seasonID,
                                                             page: page)
            } else if let seriesID = collection.meta?.series_id {
                data = try await BiliAPI.spaceSeriesArchives(mid: mid,
                                                            seriesID: seriesID,
                                                            page: page)
            } else {
                total = 0
                isLoading = false
                isLoadingMore = false
                return
            }

            let incoming = (data.archives ?? []).map { video($0) }
            if reset {
                videos = incoming
                total = data.page?.total ?? incoming.count
                page = 2
            } else {
                videos += incoming
                total = data.page?.total ?? total
                page += 1
            }
        } catch {
            if reset {
                errorMessage = error.localizedDescription
            } else {
                total = videos.count
            }
        }

        isLoading = false
        isLoadingMore = false
    }

    private func video(_ dto: SpaceArchiveDTO) -> VideoCard {
        VideoCard(id: dto.bvid ?? "av\(dto.aid ?? 0)",
                  bvid: dto.bvid,
                  aid: dto.aid,
                  title: dto.title ?? "",
                  cover: ImageURL.fix(dto.pic),
                  duration: dto.duration ?? 0,
                  upName: upName,
                  upMid: mid,
                  views: dto.stat?.view ?? 0,
                  danmaku: dto.stat?.danmaku ?? 0,
                  pubdate: dto.pubdate ?? 0)
    }
}
