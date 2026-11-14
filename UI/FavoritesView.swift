import SwiftUI

/// 收藏页：浏览当前账号的所有收藏夹与收藏内容。
struct FavoritesView: View {
    @EnvironmentObject private var app: AppState
    @State private var reloadID = 0

    var body: some View {
        Group {
            if !BiliClient.shared.isLoggedIn {
                LoginPromptView(title: "登录后即可查看收藏内容") {
                    app.showLogin = true
                }
                .background(Palette.bg)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        PageHeader(title: "收藏", subtitle: app.user?.name ?? "") {
                            PlainIconButton(systemName: "arrow.clockwise", action: {
                                reloadID += 1
                            }, help: "刷新")
                        }
                        .padding(.bottom, 2)

                        FavoriteBrowser(reloadID: reloadID)
                    }
                    .padding(Metrics.contentPadding)
                }
                .background(Palette.bg)
            }
        }
    }
}

/// 收藏夹浏览组件：我的页与收藏页共用。
struct FavoriteBrowser: View {
    @EnvironmentObject private var app: AppState
    var reloadID: Int = 0

    @State private var folders: [FavoriteFolder] = []
    @State private var selectedFolder: FavoriteFolder?
    @State private var items: [VideoCard] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading && folders.isEmpty {
                LoadingStateView()
            } else if let errorMessage, folders.isEmpty {
                ErrorStateView(message: errorMessage) {
                    Task { await reload() }
                }
            } else if folders.isEmpty {
                emptyText("暂无收藏夹")
            } else {
                foldersBar

                if items.isEmpty {
                    emptyText("这个收藏夹还是空的")
                } else {
                    VideoGrid(videos: items, openUp: { mid in
                        app.navigate(.space(mid))
                    }, onOpen: { video in
                        app.play(video: video)
                    })

                    if isLoadingMore {
                        ProgressView()
                            .controlSize(.small)
                            .padding(18)
                            .frame(maxWidth: .infinity)
                    } else if hasMore {
                        Color.clear
                            .frame(height: 2)
                            .onAppear { Task { await loadMore() } }
                    }
                }
            }
        }
        .task(id: "\(app.user?.mid ?? 0)-\(reloadID)") {
            await reload()
        }
    }

    private var foldersBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(folders) { folder in
                    PillTabButton(title: "\(folder.displayName)（\(folder.media_count ?? 0)）",
                                  selected: selectedFolder?.id == folder.id) {
                        selectedFolder = folder
                        Task { await loadItems(reset: true) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.bottom, 2)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.ui(13))
            .foregroundStyle(Palette.text3)
            .frame(maxWidth: .infinity)
            .padding(60)
    }

    // MARK: - 加载

    private func reload() async {
        guard let mid = app.user?.mid else {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let data = try await BiliAPI.favoriteFolders(mid: mid)
            folders = data.list ?? []
            if let current = selectedFolder, folders.contains(where: { $0.id == current.id }) {
                selectedFolder = current
            } else {
                selectedFolder = folders.first
            }
            await loadItems(reset: true)
        } catch {
            errorMessage = error.localizedDescription
            folders = []
            items = []
        }
        isLoading = false
    }

    private func loadItems(reset: Bool) async {
        guard let folder = selectedFolder else { return }
        if reset {
            page = 1
            items = []
        }
        do {
            let data = try await BiliAPI.favoriteList(mediaID: folder.id, page: page)
            items = (data.medias ?? []).compactMap(Self.videoCard)
            hasMore = data.has_more ?? false
            page = 2
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, let folder = selectedFolder else { return }
        isLoadingMore = true
        do {
            let data = try await BiliAPI.favoriteList(mediaID: folder.id, page: page)
            items += (data.medias ?? []).compactMap(Self.videoCard)
            hasMore = data.has_more ?? false
            page += 1
        } catch {
            hasMore = false
        }
        isLoadingMore = false
    }

    private static func videoCard(_ media: FavoriteMedia) -> VideoCard? {
        guard let bvid = media.bvid, media.title != "已失效视频" else { return nil }
        return VideoCard(id: bvid,
                         bvid: bvid,
                         title: media.title ?? "",
                         cover: ImageURL.fix(media.cover),
                         duration: media.duration ?? 0,
                         upName: media.upper?.name ?? "",
                         upFace: ImageURL.fix(media.upper?.face),
                         upMid: media.upper?.mid,
                         views: media.cnt_info?.play ?? 0,
                         danmaku: media.cnt_info?.danmaku ?? 0)
    }
}
