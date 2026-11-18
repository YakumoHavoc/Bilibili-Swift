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
    /// 粉丝数 / 关注数（来自关系统计接口）。
    @State private var relation: RelationStatData?
    @State private var userListTarget: SpaceUserListTarget?
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
        .sheet(item: $userListTarget) { target in
            SpaceUserListSheet(mid: mid,
                               upName: info?.name ?? "",
                               kind: target.kind)
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
                    countButton("粉丝", value: fansCount) {
                        userListTarget = SpaceUserListTarget(kind: .fans)
                    }
                    Text("\(Fmt.count(total)) 投稿")
                        .font(.ui(11))
                        .foregroundStyle(Palette.text3)
                    countButton("关注", value: followingCount) {
                        userListTarget = SpaceUserListTarget(kind: .following)
                    }
                }
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

    private var fansCount: Int { relation?.follower ?? info?.fans ?? 0 }
    private var followingCount: Int { relation?.following ?? info?.attention ?? 0 }

    /// 粉丝 / 关注数，点击查看对应列表。
    private func countButton(_ title: String, value: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(Fmt.count(value))
                    .foregroundStyle(Palette.blue)
                Text(title)
                    .foregroundStyle(Palette.text3)
            }
            .font(.ui(11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看\(title)列表")
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
        relation = nil
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

            // 粉丝数 / 关注数来自独立的关系统计接口，失败时保留 0。
            relation = try? await BiliAPI.relationStat(mid: mid)

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

// MARK: - 粉丝 / 关注列表

enum SpaceUserListKind {
    case fans
    case following

    var title: String {
        switch self {
        case .fans: return "粉丝"
        case .following: return "关注"
        }
    }
}

struct SpaceUserListTarget: Identifiable {
    let kind: SpaceUserListKind
    var id: String { kind.title }
}

struct SpaceUserListSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    let mid: Int
    let upName: String
    let kind: SpaceUserListKind

    @State private var users: [SpaceUser] = []
    @State private var total = 0
    @State private var page = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMore = true
    @State private var errorMessage: String?
    /// 列表搜索关键词，仅过滤已加载的用户。
    @State private var keyword = ""

    /// 按昵称或签名过滤当前已加载的用户。
    private var filteredUsers: [SpaceUser] {
        let query = keyword.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return users }
        return users.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.sign.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(kind.title)
                    .font(.ui(15, weight: .semibold))
                    .foregroundStyle(Palette.text1)
                if !upName.isEmpty {
                    Text("· \(upName)")
                        .font(.ui(12))
                        .foregroundStyle(Palette.text3)
                        .lineLimit(1)
                }
                Spacer()
                if total > 0 {
                    Text("共 \(Fmt.count(total)) 人")
                        .font(.ui(11))
                        .foregroundStyle(Palette.text3)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.ui(12, weight: .semibold))
                        .foregroundStyle(Palette.text3)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)

            searchBar

            Rectangle()
                .fill(Palette.line)
                .frame(height: 1)

            content
        }
        .frame(width: 620, height: 560)
        .background(Palette.bg)
        .task { await load(reset: true) }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && users.isEmpty {
            LoadingStateView()
                .frame(maxHeight: .infinity)
        } else if let errorMessage, users.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.ui(32, weight: .light))
                    .foregroundStyle(Palette.text3.opacity(0.7))
                Text(errorMessage)
                    .font(.ui(12))
                    .foregroundStyle(Palette.text3)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    Task { await load(reset: true) }
                }
                .buttonStyle(.borderless)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if users.isEmpty {
            Text("暂无\(kind.title)")
                .font(.ui(12))
                .foregroundStyle(Palette.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredUsers.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.ui(28, weight: .light))
                    .foregroundStyle(Palette.text3.opacity(0.7))
                Text("已加载的 \(users.count) 位用户中没有匹配结果")
                    .font(.ui(12))
                    .foregroundStyle(Palette.text3)
                if hasMore {
                    Button("继续加载更多") {
                        Task { await load(reset: false) }
                    }
                    .font(.ui(12))
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredUsers) { user in
                        userRow(user)
                    }

                    if isLoadingMore {
                        ProgressView().controlSize(.small).padding(16)
                    } else if hasMore {
                        Color.clear
                            .frame(height: 2)
                            .onAppear { Task { await load(reset: false) } }
                    } else if !keyword.isEmpty {
                        Text("以上为全部 \(users.count) 位用户的搜索结果")
                            .font(.ui(11))
                            .foregroundStyle(Palette.text3)
                            .padding(.vertical, 14)
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.ui(11))
                .foregroundStyle(Palette.text3)
            TextField("搜索\(kind.title)昵称", text: $keyword)
                .textFieldStyle(.plain)
                .font(.ui(12))
                .foregroundStyle(Palette.text1)
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.ui(11))
                        .foregroundStyle(Palette.text3.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Palette.bgRegular)
        .clipShape(Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func userRow(_ user: SpaceUser) -> some View {
        Button {
            dismiss()
            app.navigate(.space(user.id))
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: ImageURL.thumb(user.face, width: 80, height: 80), size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(user.name)
                        .font(.ui(13, weight: .medium))
                        .foregroundStyle(Palette.text1)
                        .lineLimit(1)
                    Text(user.sign.isEmpty ? " " : user.sign)
                        .font(.ui(11))
                        .foregroundStyle(Palette.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.ui(10, weight: .semibold))
                    .foregroundStyle(Palette.text3.opacity(0.6))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load(reset: Bool) async {
        if reset {
            isLoading = true
            errorMessage = nil
            page = 1
            users = []
            hasMore = true
        } else {
            guard !isLoadingMore, hasMore else { return }
            isLoadingMore = true
        }

        do {
            let data: SpaceUserListData
            switch kind {
            case .fans:
                data = try await BiliAPI.spaceFans(mid: mid, page: page)
            case .following:
                data = try await BiliAPI.spaceFollowings(mid: mid, page: page)
            }
            let incoming = (data.list ?? []).compactMap { dto -> SpaceUser? in
                guard let id = dto.mid else { return nil }
                return SpaceUser(id: id,
                                 name: dto.uname ?? "",
                                 face: dto.face ?? "",
                                 sign: dto.sign ?? "")
            }
            if reset {
                users = incoming
                total = data.count ?? data.total ?? incoming.count
                page = 2
            } else {
                users += incoming
                total = data.count ?? data.total ?? total
                page += 1
            }
            // 接口未返回总数时，本页满 30 条才认为还有下一页。
            if let count = data.count ?? data.total {
                hasMore = users.count < count
            } else {
                hasMore = incoming.count >= 30
            }
        } catch {
            if reset {
                errorMessage = message(for: error)
            } else {
                hasMore = false
            }
        }

        isLoading = false
        isLoadingMore = false
    }

    private func message(for error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("412") || text.contains("风控") || text.contains("-352") {
            return "接口触发风控，请稍后重试"
        }
        if text.contains("-101") || text.contains("未登录") {
            return "登录后才能查看列表"
        }
        if kind == .following {
            return "无法获取关注列表，对方可能已设置隐私"
        }
        return "加载失败：\(text)"
    }
}
