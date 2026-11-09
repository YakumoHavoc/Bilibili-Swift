import SwiftUI
import AppKit

enum DynamicFilter: String, CaseIterable, Identifiable {
    case all
    case video
    case pgc
    case article

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .video: return "视频投稿"
        case .pgc: return "追番追剧"
        case .article: return "专栏"
        }
    }
}

struct DynamicView: View {
    @EnvironmentObject private var app: AppState

    /// 记录各 UP 主“已看过”的最新动态时间（秒级时间戳）。
    private static let seenBaselineKey = "dynamic.seenByMid.v2"

    @State private var filter: DynamicFilter = .all
    @State private var items: [DynamicItem] = []
    @State private var offset: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasMore = true
    @State private var followings: [FollowingUser] = []
    @State private var allFollowings: [FollowingUser] = []
    @State private var lives: [FollowingLiveRoom] = []
    @State private var updatedMids: Set<Int> = []
    /// 有新动态的 UP 主（取自动态流本身，不依赖关注列表首页）。
    @State private var updateAuthors: [FollowingUser] = []
    @State private var commentTarget: DynamicItem?
    @State private var imageViewer: ImageViewerPayload?
    @State private var forwardTarget: DynamicDetailTarget?

    var body: some View {
        Group {
            if !BiliClient.shared.isLoggedIn {
                LoginPromptView(title: "登录后即可查看关注的 UP 主动态") {
                    app.showLogin = true
                }
                .background(Palette.bg)
            } else {
                HStack(spacing: 0) {
                    if !lives.isEmpty {
                        liveSidebar
                        Rectangle()
                            .fill(Palette.line)
                            .frame(width: 1)
                    }
                    feedArea
                }
            }
        }
        .background(Palette.bg)
        .onDisappear { markSeen() }
        .sheet(item: $commentTarget) { item in
            DynamicCommentsSheet(dynamic: item)
        }
        .sheet(item: $imageViewer) { payload in
            ImageViewerSheet(payload: payload)
        }
        .sheet(item: $forwardTarget) { target in
            DynamicDetailSheet(target: target)
        }
        .task {
            guard BiliClient.shared.isLoggedIn else { return }
            await loadSidebar()
            if items.isEmpty { await reload() }
        }
        .onChange(of: app.user?.mid) { _, _ in
            guard BiliClient.shared.isLoggedIn else { return }
            Task {
                await loadSidebar()
                await reload()
            }
        }
        .onChange(of: app.refreshToken) { _, _ in
            guard BiliClient.shared.isLoggedIn else { return }
            Task {
                await loadSidebar()
                await reload()
            }
        }
    }

    // MARK: - 左侧：正在直播

    private var liveSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("正在直播")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text1)
                Text("\(lives.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.pink)
                Spacer()
                Button {
                    app.navigate(.live)
                } label: {
                    HStack(spacing: 2) {
                        Text("更多关注")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(lives) { room in
                        Button {
                            PlayerWindowController.shared.openLive(room: room.asLiveRoom, app: app)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                ZStack(alignment: .bottomLeading) {
                                    RemoteImage(url: ImageURL.thumb(room.cover, width: 112, height: 112))
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    Text("直播中")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Palette.pink)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                        .offset(x: 3, y: -3)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(room.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Palette.text2)
                                        .lineLimit(1)
                                    Text(room.title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.text3)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text("\(Fmt.count(room.online)) 人气")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Palette.text3)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
            }
        }
        .frame(width: 228)
    }

    // MARK: - 右侧动态流

    private var feedArea: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                avatarRow
                tabs

                Rectangle()
                    .fill(Palette.line)
                    .frame(height: 1)

                if isLoading && items.isEmpty {
                    LoadingStateView()
                } else if let errorMessage, items.isEmpty {
                    ErrorStateView(message: errorMessage) { Task { await reload() } }
                } else {
                    ForEach(items) { item in
                        DynamicCardView(item: item) { bvid, title in
                            app.play(video: VideoCard(id: bvid, bvid: bvid, title: title,
                                                      cover: "", duration: 0))
                        } onOpenSpace: { mid in
                            app.navigate(.space(mid))
                        } onOpenComments: {
                            commentTarget = item
                        } onOpenImages: { urls, index in
                            imageViewer = ImageViewerPayload(images: urls, index: index)
                        } onOpenForward: { item in
                            forwardTarget = DynamicDetailTarget(item: item)
                        }

                        Rectangle()
                            .fill(Palette.line)
                            .frame(height: 1)
                    }

                    if isLoadingMore {
                        ProgressView()
                            .controlSize(.small)
                            .padding(18)
                            .frame(maxWidth: .infinity)
                    } else if hasMore {
                        Color.clear
                            .frame(height: 2)
                            .onAppear { Task { await loadMore() } }
                    } else {
                        Text("没有更多动态了")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.text3)
                            .frame(maxWidth: .infinity)
                            .padding(20)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private var avatarRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                Button {
                    markSeen()
                    updatedMids = []
                    updateAuthors = []
                    applyFollowingsOrder()
                    if filter != .all {
                        filter = .all
                        Task { await reload() }
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(Palette.blue.opacity(0.12))
                            Image(systemName: "circle.hexagongrid.fill")
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(Palette.blue)
                        }
                        .frame(width: 44, height: 44)

                        Text("全部动态")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.blue)
                            .lineLimit(1)
                            .frame(width: 64)
                            .frame(minHeight: 30, alignment: .top)
                    }
                    .frame(width: 64)
                }
                .buttonStyle(.plain)
                .help("回到全部动态")

                ForEach(followings) { user in
                    Button {
                        markSeen(mid: user.id)
                        updatedMids.remove(user.id)
                        updateAuthors.removeAll { $0.id == user.id }
                        applyFollowingsOrder()
                        app.navigate(.space(user.id))
                    } label: {
                        VStack(spacing: 6) {
                            AvatarView(url: ImageURL.thumb(user.face, width: 96, height: 96), size: 44)
                                .overlay(alignment: .bottomTrailing) {
                                    if updatedMids.contains(user.id) {
                                        Circle()
                                            .fill(Palette.blue)
                                            .frame(width: 11, height: 11)
                                            .overlay(Circle().stroke(Palette.bg, lineWidth: 2))
                                            .offset(x: 1, y: -1)
                                    }
                                }

                            Text(user.name)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.text2)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .frame(width: 64)
                                .frame(minHeight: 30, alignment: .top)
                        }
                        .frame(width: 64)
                    }
                    .buttonStyle(.plain)
                    .help(updatedMids.contains(user.id) ? "\(user.name) 有新动态" : user.name)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 2)
        }
    }

    private var tabs: some View {
        HStack(spacing: 26) {
            ForEach(DynamicFilter.allCases) { tab in
                Button {
                    guard tab != filter else { return }
                    filter = tab
                    Task { await reload() }
                } label: {
                    VStack(spacing: 6) {
                        Text(tab.title)
                            .font(.system(size: 14, weight: tab == filter ? .semibold : .regular))
                            .foregroundStyle(tab == filter ? Palette.text1 : Palette.text3)
                        Rectangle()
                            .fill(tab == filter ? Palette.pink : Color.clear)
                            .frame(width: 22, height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.bottom, 6)
    }

    // MARK: - 数据

    private func loadSidebar() async {
        if let mid = app.user?.mid,
           let data = try? await BiliAPI.followings(mid: mid) {
            allFollowings = (data.list ?? []).compactMap { dto in
                guard let mid = dto.mid else { return nil }
                return FollowingUser(id: mid, name: dto.uname ?? "", face: ImageURL.fix(dto.face))
            }
            applyFollowingsOrder()
        }
        if let data = try? await BiliAPI.followingLiveFeed() {
            lives = (data.list ?? []).map { FollowingLiveRoom(dto: $0) }
        }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        offset = nil
        hasMore = true
        do {
            let data = try await BiliAPI.dynamicFeed(type: filter.rawValue)
            items = data.items ?? []
            offset = data.offset
            hasMore = data.has_more ?? false
            detectUpdates()
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 对比上次离开动态页时记录的各 UP 主最新动态时间，找出有新动态的 UP 主。
    /// 这里只读取基线，真正推进基线在 `markSeen()`（离开页面或点开该 UP 时）。
    private func detectUpdates() {
        let stored = seenMap()
        var latest: [String: Int] = [:]

        for item in items {
            guard let mid = item.modules?.module_author?.mid,
                  let ts = item.modules?.module_author?.pub_ts else { continue }
            latest[String(mid)] = max(latest[String(mid)] ?? 0, ts)
        }

        // 首次使用（或旧版本升级）没有基线时，把最近 24 小时的动态视为“有更新”，
        // 否则新用户永远看不到任何标记。
        let firstRunCutoff = Int(Date().timeIntervalSince1970) - 24 * 3600
        var updated: Set<Int> = []
        for (midKey, ts) in latest {
            guard let mid = Int(midKey) else { continue }
            if let seen = stored[midKey] {
                if ts > seen { updated.insert(mid) }
            } else if ts > firstRunCutoff {
                updated.insert(mid)
            }
        }
        updatedMids = updated

        // 关注列表只加载了首页（30 个），动态流里的 UP 往往不在其中，
        // 这里用动态作者补全头像行，保证有更新的 UP 一定能显示出来并带标记。
        var seenAuthors = Set<Int>()
        updateAuthors = items.compactMap { item -> FollowingUser? in
            guard let author = item.modules?.module_author,
                  let mid = author.mid, updated.contains(mid),
                  seenAuthors.insert(mid).inserted else { return nil }
            return FollowingUser(id: mid,
                                 name: author.name ?? "UP主",
                                 face: ImageURL.fix(author.face))
        }
        applyFollowingsOrder()
    }

    private func seenMap() -> [String: Int] {
        let raw = UserDefaults.standard.dictionary(forKey: Self.seenBaselineKey) as? [String: NSNumber] ?? [:]
        return raw.mapValues { $0.intValue }
    }

    /// 把当前 feed 中各 UP 的最新动态时间写入基线，作为“已看过”的位置。
    /// 传入 mid 时只推进该 UP 主，用于点击头像的场景。
    private func markSeen(mid: Int? = nil) {
        var stored = seenMap()
        for item in items {
            guard let itemMid = item.modules?.module_author?.mid,
                  let ts = item.modules?.module_author?.pub_ts else { continue }
            if let mid, itemMid != mid { continue }
            let key = String(itemMid)
            stored[key] = max(stored[key] ?? 0, ts)
        }
        UserDefaults.standard.set(stored, forKey: Self.seenBaselineKey)
    }

    /// 有新动态的 UP 主排到前面，其余保持关注列表原顺序。
    private func applyFollowingsOrder() {
        let updatedIds = Set(updateAuthors.map(\.id))
        followings = updateAuthors + allFollowings.filter { !updatedIds.contains($0.id) }
    }

    private func loadMore() async {
        guard !isLoading, !isLoadingMore, hasMore, let offset else { return }
        isLoadingMore = true
        do {
            let data = try await BiliAPI.dynamicFeed(type: filter.rawValue, offset: offset)
            items += data.items ?? []
            self.offset = data.offset
            hasMore = data.has_more ?? false
        } catch {
            hasMore = false
        }
        isLoadingMore = false
    }
}

// MARK: - 动态卡片

struct DynamicImageItem {
    let url: String
    let width: Int?
    let height: Int?
}

struct DynamicCardView: View {
    let item: DynamicItem
    let onOpenVideo: (String, String) -> Void
    let onOpenSpace: (Int) -> Void
    let onOpenComments: () -> Void
    /// 打开大图：传入整个图片列表与起始下标，由页面级 sheet 展示原图。
    let onOpenImages: ([String], Int) -> Void
    /// 打开转发原动态的详情。
    let onOpenForward: (DynamicItem) -> Void

    @State private var expanded = false

    private var author: DynamicAuthor? { item.modules?.module_author }
    private var content: DynamicContent? { item.modules?.module_dynamic }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if let mid = author?.mid { onOpenSpace(mid) }
            } label: {
                AvatarView(url: ImageURL.thumb(author?.face, width: 96, height: 96), size: 40)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 9) {
                header

                if let text = text(for: content) {
                    descText(text)
                }

                if !images(for: content).isEmpty {
                    DynamicImageGallery(images: images(for: content)) { urls, index in
                        onOpenImages(urls, index)
                    }
                }
                if let archive = content?.major?.archive {
                    archiveCard(archive)
                }
                if let article = content?.major?.article {
                    articleCard(article)
                }
                if let pgc = content?.major?.pgc {
                    pgcCard(pgc)
                }

                if let orig = item.orig {
                    forwardCard(orig)
                }

                footer
            }
        }
        .padding(.vertical, 18)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(author?.name ?? "未知用户")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text2)
            Text(author?.pub_time ?? Fmt.relativeDate(author?.pub_ts ?? 0))
                .font(.system(size: 11))
                .foregroundStyle(Palette.text3)
            Spacer()
            Menu {
                if item.orig != nil {
                    Button("查看原动态详情") { onOpenForward(item) }
                }
                Button("查看评论", action: onOpenComments)
                Button("在浏览器打开") {
                    if let url = URL(string: "https://t.bilibili.com/\(item.id_str)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text3)
                    .frame(width: 22, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func descText(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text1)
                .lineSpacing(4)
                .lineLimit(expanded ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)

            if text.count > 120 {
                Button(expanded ? "收起" : "展开") { expanded.toggle() }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text3)
                    .buttonStyle(.plain)
            }
        }
    }

    private func text(for content: DynamicContent?) -> String? {
        dynamicText(from: content)
    }

    private func images(for content: DynamicContent?) -> [DynamicImageItem] {
        dynamicImages(from: content)
    }

    @ViewBuilder
    private func archiveCard(_ archive: DynamicArchive) -> some View {
        Button {
            if let bvid = archive.bvid {
                onOpenVideo(bvid, archive.title ?? "")
            }
        } label: {
            HStack(spacing: 10) {
                RemoteImage(url: ImageURL.thumb(archive.cover, width: 320, height: 200))
                    .frame(width: 132, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 6) {
                    Text(archive.title ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text1)
                        .lineLimit(2)
                    if let play = archive.stat?.play {
                        Text("\(play) 播放")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.text3)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(Palette.bgThin)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder
    private func articleCard(_ article: DynamicArticle) -> some View {
        Button {
            openWeb(article.jump_url)
        } label: {
            HStack(spacing: 10) {
                RemoteImage(url: ImageURL.thumb(article.covers?.first, width: 320, height: 200))
                    .frame(width: 132, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 6) {
                    Text(article.title ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text1)
                        .lineLimit(2)
                    if let desc = article.desc, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.text3)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(Palette.bgThin)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder
    private func pgcCard(_ pgc: DynamicPGC) -> some View {
        Button {
            openWeb(pgc.jump_url)
        } label: {
            HStack(spacing: 10) {
                RemoteImage(url: ImageURL.thumb(pgc.cover, width: 320, height: 200))
                    .frame(width: 132, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 6) {
                    Text(pgc.title ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text1)
                        .lineLimit(2)
                    Text("番剧")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                }
                Spacer()
            }
            .padding(8)
            .background(Palette.bgThin)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder
    private func forwardCard(_ orig: DynamicOrig) -> some View {
        let origAuthor = orig.modules?.module_author
        let origContent = orig.modules?.module_dynamic

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AvatarView(url: ImageURL.thumb(origAuthor?.face, width: 64, height: 64), size: 18)
                Text(origAuthor?.name ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text2)
                Text(origAuthor?.pub_time ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.text3)
                Spacer()
            }

            if let text = text(for: origContent) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
                    .lineSpacing(3)
                    .lineLimit(expanded ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !images(for: origContent).isEmpty {
                DynamicImageGallery(images: images(for: origContent)) { urls, index in
                    onOpenImages(urls, index)
                }
            }
            if let archive = origContent?.major?.archive {
                archiveCard(archive)
            }
            if let article = origContent?.major?.article {
                articleCard(article)
            }
            if let pgc = origContent?.major?.pgc {
                pgcCard(pgc)
            }
        }
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Palette.bgThin)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenForward(item)
        }
        .help("查看原动态详情")
    }

    private var footer: some View {
        HStack(spacing: 42) {
            HStack(spacing: 5) {
                Image(systemName: "arrowshape.turn.up.right")
                Text(item.modules?.module_stat?.forward?.count.map(Fmt.count) ?? "")
            }
            HStack(spacing: 5) {
                Image(systemName: "bubble.right")
                Text(item.modules?.module_stat?.comment?.count.map(Fmt.count) ?? "")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenComments)
            .help("查看评论")
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "hand.thumbsup")
                Text(item.modules?.module_stat?.like?.count.map(Fmt.count) ?? "")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.text3)
        .padding(.top, 2)
    }

    private func openWeb(_ raw: String?) {
        guard let raw else { return }
        let fixed = ImageURL.fix(raw)
        guard !fixed.isEmpty, let url = URL(string: fixed) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 动态配图

/// 动态配图：单图等比缩小到 320 以内，多图 112pt 网格，点击查看原图。
struct DynamicImageGallery: View {
    let images: [DynamicImageItem]
    let onOpen: ([String], Int) -> Void

    var body: some View {
        let urls = images.map(\.url)
        if images.count == 1, let image = images.first {
            // 单图整体等比缩放到 320×320 以内，避免长图被放大裁切。
            let size = singleImageSize(image)
            RemoteImage(url: ImageURL.thumb(image.url, width: 720, height: 720),
                        contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { onOpen(urls, 0) }
                .help("查看原图")
        } else {
            let columns = Array(repeating: GridItem(.fixed(112), spacing: 6),
                                count: min(3, max(1, images.count)))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(Array(images.prefix(9).enumerated()), id: \.offset) { index, image in
                    RemoteImage(url: ImageURL.thumb(image.url, width: 320, height: 320))
                        .frame(width: 112, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(urls, index) }
                        .help("查看原图")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func singleImageSize(_ image: DynamicImageItem) -> CGSize {
        let maxSide: CGFloat = 320
        guard let width = image.width, let height = image.height,
              width > 0, height > 0 else {
            return CGSize(width: maxSide, height: maxSide * 10 / 16)
        }
        let ratio = CGFloat(width) / CGFloat(height)
        if ratio >= 1 {
            return CGSize(width: maxSide, height: maxSide / ratio)
        } else {
            return CGSize(width: maxSide * ratio, height: maxSide)
        }
    }
}

private func dynamicText(from content: DynamicContent?) -> String? {
    if let text = content?.desc?.text, !text.isEmpty { return text }
    if let text = content?.major?.opus?.summary?.text, !text.isEmpty { return text }
    return nil
}

private func dynamicImages(from content: DynamicContent?) -> [DynamicImageItem] {
    if let pics = content?.major?.opus?.pics, !pics.isEmpty {
        return pics.compactMap { pic in
            guard let url = pic.url, !url.isEmpty else { return nil }
            return DynamicImageItem(url: url, width: pic.width, height: pic.height)
        }
    }
    if let items = content?.major?.draw?.items, !items.isEmpty {
        return items.compactMap { item in
            guard let src = item.src, !src.isEmpty else { return nil }
            return DynamicImageItem(url: src, width: item.width, height: item.height)
        }
    }
    return []
}

// MARK: - 动态详情

struct DynamicDetailTarget: Identifiable {
    let id = UUID()
    let author: DynamicAuthor?
    let content: DynamicContent?
    let commentType: Int
    let commentID: String
    let refererID: String

    init(item: DynamicItem) {
        author = item.orig?.modules?.module_author
        content = item.orig?.modules?.module_dynamic
        // 转发的评论挂在转发动态本身（type=17，oid 为长 id）；
        // 原动态的 basic 常见为 0/空，直接拿来请求会得到「请求错误」。
        let type = item.basic?.comment_type ?? 0
        let oid = item.basic?.comment_id_str ?? ""
        if type > 0, !oid.isEmpty {
            commentType = type
            commentID = oid
        } else if let orig = item.orig,
                  let origType = orig.basic?.comment_type, origType > 0,
                  let origID = orig.basic?.comment_id_str, !origID.isEmpty {
            commentType = origType
            commentID = origID
        } else {
            commentType = 17
            commentID = item.id_str
        }
        refererID = item.id_str
    }
}

/// 转发详情：原动态完整正文 + 配图 + 该转发动态的评论。
struct DynamicDetailSheet: View {
    let target: DynamicDetailTarget

    @Environment(\.dismiss) private var dismiss
    @State private var viewer: ImageViewerPayload?
    @State private var total = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("动态详情")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.text1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
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
                VStack(alignment: .leading, spacing: 14) {
                    authorRow

                    if let text = dynamicText(from: target.content) {
                        Text(text)
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.text1)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let images = dynamicImages(from: target.content)
                    if !images.isEmpty {
                        DynamicImageGallery(images: images) { urls, index in
                            viewer = ImageViewerPayload(images: urls, index: index)
                        }
                    }

                    Rectangle()
                        .fill(Palette.line)
                        .frame(height: 1)

                    HStack(spacing: 6) {
                        Text("评论")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.text1)
                        if total > 0 {
                            Text(Fmt.count(total))
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.text3)
                        }
                    }

                    DynamicCommentList(commentType: target.commentType,
                                       commentID: target.commentID,
                                       refererID: target.refererID,
                                       note: nil,
                                       total: $total,
                                       embedded: true)
                }
                .padding(20)
            }
        }
        .frame(width: 620, height: 760)
        .background(Palette.bg)
        .sheet(item: $viewer) { payload in
            ImageViewerSheet(payload: payload)
        }
    }

    private var authorRow: some View {
        HStack(spacing: 10) {
            AvatarView(url: ImageURL.thumb(target.author?.face, width: 96, height: 96), size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(target.author?.name ?? "未知用户")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text2)
                Text(target.author?.pub_time ?? Fmt.relativeDate(target.author?.pub_ts ?? 0))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 动态评论

struct DynamicCommentsSheet: View {
    let dynamic: DynamicItem

    @Environment(\.dismiss) private var dismiss
    @State private var total = 0

    /// 评论接口的 type/oid 来自 feed 的 `basic`，不能直接用动态 id。
    private var commentType: Int { dynamic.basic?.comment_type ?? 17 }
    private var commentID: String { dynamic.basic?.comment_id_str ?? dynamic.id_str }
    private var author: String { dynamic.modules?.module_author?.name ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("评论")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.text1)
                if total > 0 {
                    Text(Fmt.count(total))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text3)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
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

            DynamicCommentList(commentType: commentType,
                               commentID: commentID,
                               refererID: dynamic.id_str,
                               note: author.isEmpty ? nil : "来自 \(author) 的动态",
                               total: $total,
                               embedded: false)
        }
        .frame(width: 560, height: 640)
        .background(Palette.bg)
    }
}

/// 评论列表：既可用于独立弹窗，也可嵌在动态详情页里。
struct DynamicCommentList: View {
    let commentType: Int
    let commentID: String
    let refererID: String
    let note: String?
    @Binding var total: Int
    /// true 表示不自带滚动容器，由外层 ScrollView 滚动。
    let embedded: Bool

    @State private var replies: [Reply] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var viewer: ImageViewerPayload?

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                ScrollView { content }
            }
        }
        .sheet(item: $viewer) { payload in
            ImageViewerSheet(payload: payload)
        }
        .task { await load(reset: true) }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && replies.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在加载评论…")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if let errorMessage, replies.isEmpty {
            VStack(spacing: 10) {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text3)
                Button("重试") { Task { await load(reset: true) } }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if replies.isEmpty {
            Text("暂无评论")
                .font(.system(size: 12))
                .foregroundStyle(Palette.text3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                }
                ForEach(replies) { reply in
                    replyRow(reply)
                }
                if isLoadingMore {
                    ProgressView().controlSize(.mini)
                        .frame(maxWidth: .infinity)
                } else if hasMore {
                    Color.clear
                        .frame(height: 2)
                        .onAppear { Task { await load(reset: false) } }
                } else {
                    Text("没有更多评论了")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(embedded ? 0 : 20)
        }
    }

    private func replyRow(_ reply: Reply) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: ImageURL.thumb(reply.member?.avatar, width: 64, height: 64), size: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(reply.member?.uname ?? "匿名用户")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.text2)
                    Text(Fmt.relativeDate(reply.ctime ?? 0))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                }
                if let content = reply.content {
                    CommentMessageText(message: content.message ?? "",
                                       emotes: content.emote ?? [:])

                    if let pictures = content.pictures, !pictures.isEmpty {
                        let urls = pictures.compactMap { ImageURL.fix($0.img_src) }
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(92), spacing: 6),
                                                 count: min(3, max(1, urls.count))),
                                  alignment: .leading,
                                  spacing: 6) {
                            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                                RemoteImage(url: ImageURL.thumb(url, width: 240, height: 240))
                                    .frame(width: 92, height: 92)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        viewer = ImageViewerPayload(images: urls, index: index)
                                    }
                                    .help("查看原图")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let like = reply.like, like > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.thumbsup")
                        Text(Fmt.count(like))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.text3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func load(reset: Bool) async {
        if reset {
            isLoading = true
            errorMessage = nil
            page = 1
            hasMore = true
        } else {
            guard hasMore, !isLoadingMore else { return }
            isLoadingMore = true
        }

        do {
            let data = try await BiliAPI.dynamicReplies(oid: commentID,
                                                        commentType: commentType,
                                                        refererID: refererID,
                                                        page: page)
            let incoming = data.replies ?? []
            if reset {
                replies = incoming
                total = data.page?.count ?? incoming.count
                page = 2
            } else {
                replies += incoming
                page += 1
            }
            hasMore = incoming.count >= 20
        } catch {
            if reset {
                replies = []
                errorMessage = error.localizedDescription
            } else {
                hasMore = false
            }
        }

        isLoading = false
        isLoadingMore = false
    }
}

// MARK: - 评论正文（支持 [表情] 与配图）

struct CommentMessageText: View {
    let message: String
    let emotes: [String: ReplyEmote]

    @State private var images: [String: NSImage] = [:]

    var body: some View {
        text
            .font(.system(size: 13))
            .foregroundStyle(Palette.text1)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .task(id: message) { await loadEmotes() }
    }

    /// 把 [表情名] 替换成等比缩放的图片，其余文本原样拼接，保留自动换行。
    private var text: Text {
        guard !emotes.isEmpty else { return Text(message) }

        var result = Text(verbatim: "")
        var buffer = ""
        var index = message.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            result = result + Text(buffer)
            buffer = ""
        }

        while index < message.endIndex {
            if message[index] == "[",
               let close = message[index...].firstIndex(of: "]") {
                let token = String(message[index...close])
                if let image = images[token] {
                    flush()
                    result = result + Text(Image(nsImage: image)).baselineOffset(-2)
                    index = message.index(after: close)
                    continue
                }
            }
            buffer.append(message[index])
            index = message.index(after: index)
        }
        flush()
        return result
    }

    private func loadEmotes() async {
        guard !emotes.isEmpty else { return }
        var loaded: [String: NSImage] = [:]
        for (token, emote) in emotes {
            let url = ImageURL.fix(emote.url)
            guard !url.isEmpty, let image = await ImageLoader.shared.load(url) else { continue }
            loaded[token] = Self.scaled(image, side: 18)
        }
        images = loaded
    }

    private static func scaled(_ image: NSImage, side: CGFloat) -> NSImage {
        let size = NSSize(width: side, height: side)
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        resized.unlockFocus()
        return resized
    }
}

// MARK: - 原图查看

struct ImageViewerPayload: Identifiable {
    let id = UUID()
    let images: [String]
    let index: Int
}

struct ImageViewerSheet: View {
    let images: [String]
    @State private var index: Int
    @State private var image: NSImage?
    @Environment(\.dismiss) private var dismiss

    init(payload: ImageViewerPayload) {
        images = payload.images
        _index = State(initialValue: min(max(payload.index, 0),
                                        max(0, payload.images.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            VStack {
                HStack {
                    Text(images.isEmpty ? "" : "\(index + 1) / \(images.count)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(14)

                Spacer()

                if images.count > 1 {
                    HStack(spacing: 18) {
                        Button {
                            index = max(0, index - 1)
                        } label: {
                            chevron("chevron.left")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == 0)

                        Button {
                            index = min(images.count - 1, index + 1)
                        } label: {
                            chevron("chevron.right")
                        }
                        .buttonStyle(.plain)
                        .disabled(index >= images.count - 1)
                    }
                    .padding(.bottom, 18)
                }
            }
        }
        .frame(width: 960, height: 720)
        .background(Color.black)
        .task(id: index) {
            image = nil
            guard images.indices.contains(index) else { return }
            image = await ImageLoader.shared.load(ImageURL.fix(images[index]))
        }
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.14))
            .clipShape(Circle())
    }
}
