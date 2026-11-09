import SwiftUI
import AppKit

struct SpaceView: View {
    @EnvironmentObject private var app: AppState
    let mid: Int

    @State private var info: SpaceInfoData?
    @State private var videos: [VideoCard] = []
    @State private var page = 1
    @State private var total = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    private var hasMore: Bool { videos.count < total }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let info {
                    header(info)
                }

                if isLoading && videos.isEmpty {
                    LoadingStateView()
                } else if let errorMessage, videos.isEmpty {
                    ErrorStateView(message: errorMessage) { Task { await reload() } }
                } else {
                    Text("TA 的投稿")
                        .font(.system(size: 16, weight: .semibold))
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
            .padding(Metrics.contentPadding)
        }
        .background(Palette.bg)
        .task(id: mid) { await reload() }
        .onChange(of: app.refreshToken) { _, _ in Task { await reload() } }
    }

    private func header(_ info: SpaceInfoData) -> some View {
        HStack(alignment: .center, spacing: 18) {
            AvatarView(url: ImageURL.thumb(info.face, width: 200, height: 200), size: 84)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(info.name ?? "UP主")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.text1)
                    Text("Lv\(info.level ?? 0)")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.pink)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Palette.pink.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(info.sign ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(2)
                HStack(spacing: 16) {
                    Text("\(Fmt.count(info.fans ?? 0)) 粉丝")
                    Text("\(Fmt.count(total)) 投稿")
                    Text("\(Fmt.count(info.attention ?? 0)) 关注")
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.text3)
            }
            Spacer()
            if let url = URL(string: "https://space.bilibili.com/\(mid)") {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("在浏览器打开")
                        .font(.system(size: 12))
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
