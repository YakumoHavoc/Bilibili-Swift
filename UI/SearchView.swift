import SwiftUI

enum SearchTab: String, CaseIterable, Identifiable {
    case video
    case user

    var id: String { rawValue }
    var title: String { self == .video ? "视频" : "UP主" }
}

struct SearchView: View {
    @EnvironmentObject private var app: AppState
    let keyword: String

    @State private var tab: SearchTab = .video
    @State private var sort = "totalrank"
    @State private var videos: [VideoCard] = []
    @State private var users: [SearchUserDTO] = []
    @State private var page = 1
    @State private var numPages = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    private let sortOptions: [(String, String)] = [
        ("totalrank", "综合排序"),
        ("click", "最多播放"),
        ("pubdate", "最新发布"),
        ("dm", "最多弹幕")
    ]

    private var hasMore: Bool { page < numPages }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "搜索结果", subtitle: keyword)
                    .padding(.bottom, 10)

                HStack(spacing: 6) {
                    ForEach(SearchTab.allCases) { item in
                        PillTabButton(title: item.title, selected: tab == item) {
                            tab = item
                            Task { await reload() }
                        }
                    }
                }
                .padding(.bottom, 8)

                if tab == .video {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(sortOptions, id: \.0) { option in
                                PillTabButton(title: option.1, selected: sort == option.0) {
                                    sort = option.0
                                    Task { await reload() }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .padding(.bottom, 8)
                }

                if isLoading && videos.isEmpty && users.isEmpty {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) { Task { await reload() } }
                } else {
                    if tab == .video {
                        VideoGrid(videos: videos, openUp: { mid in
                            app.navigate(.space(mid))
                        }, onOpen: { video in
                            app.play(video: video)
                        })
                        if videos.isEmpty {
                            emptyView
                        }
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(users.enumerated()), id: \.offset) { _, user in
                                userRow(user)
                            }
                        }
                        if users.isEmpty {
                            emptyView
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
        .task(id: keyword) { await reload() }
        .onChange(of: app.refreshToken) { _, _ in Task { await reload() } }
    }

    private var emptyView: some View {
        Text("没有找到相关内容")
            .font(.system(size: 13))
            .foregroundStyle(Palette.text3)
            .frame(maxWidth: .infinity)
            .padding(60)
    }

    private func userRow(_ user: SearchUserDTO) -> some View {
        Button {
            if let mid = user.mid { app.navigate(.space(mid)) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: ImageURL.thumb(user.upic, width: 96, height: 96), size: 52)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(user.uname ?? "")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Palette.text1)
                        if let verify = user.official_verify, verify.type == 0 {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.blue)
                        }
                        Text("Lv\(user.level ?? 0)")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.text3)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Palette.bgRegular)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text(user.usign ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text3)
                        .lineLimit(1)
                    Text("\(Fmt.count(user.fans ?? 0)) 粉丝 · \(Fmt.count(user.videos ?? 0)) 投稿")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
            }
            .padding(12)
            .background(Palette.bgThin)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        page = 1
        do {
            if tab == .video {
                let data = try await BiliAPI.searchVideos(keyword: keyword, page: 1, sort: sort)
                videos = (data.result ?? []).map { dto in
                    VideoCard(id: dto.bvid ?? "av\(dto.aid ?? 0)",
                              bvid: dto.bvid,
                              aid: dto.aid,
                              title: Fmt.stripHTML(dto.title ?? ""),
                              cover: ImageURL.fix(dto.pic),
                              duration: Fmt.durationString(dto.duration),
                              upName: dto.author ?? "",
                              upFace: ImageURL.fix(dto.upic),
                              upMid: dto.mid,
                              views: dto.play ?? 0,
                              danmaku: dto.video_review ?? 0,
                              pubdate: dto.pubdate ?? 0,
                              badge: dto.typename)
                }
                numPages = data.numPages ?? 1
            } else {
                let data = try await BiliAPI.searchUsers(keyword: keyword, page: 1)
                users = data.result ?? []
                numPages = data.numPages ?? 1
            }
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
            if tab == .video {
                let data = try await BiliAPI.searchVideos(keyword: keyword, page: page, sort: sort)
                videos += (data.result ?? []).map { dto in
                    VideoCard(id: dto.bvid ?? "av\(dto.aid ?? 0)",
                              bvid: dto.bvid,
                              aid: dto.aid,
                              title: Fmt.stripHTML(dto.title ?? ""),
                              cover: ImageURL.fix(dto.pic),
                              duration: Fmt.durationString(dto.duration),
                              upName: dto.author ?? "",
                              upFace: ImageURL.fix(dto.upic),
                              upMid: dto.mid,
                              views: dto.play ?? 0,
                              danmaku: dto.video_review ?? 0,
                              pubdate: dto.pubdate ?? 0,
                              badge: dto.typename)
                }
                numPages = data.numPages ?? numPages
            } else {
                let data = try await BiliAPI.searchUsers(keyword: keyword, page: page)
                users += data.result ?? []
                numPages = data.numPages ?? numPages
            }
            page += 1
        } catch {
            numPages = 1
        }
        isLoadingMore = false
    }
}
