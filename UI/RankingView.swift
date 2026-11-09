import SwiftUI

struct RankingCategory: Identifiable, Hashable {
    let id: Int
    let name: String
}

struct RankingView: View {
    @EnvironmentObject private var app: AppState

    private let categories: [RankingCategory] = [
        .init(id: 0, name: "全站"),
        .init(id: 1, name: "动画"),
        .init(id: 13, name: "番剧"),
        .init(id: 168, name: "国创"),
        .init(id: 3, name: "音乐"),
        .init(id: 129, name: "舞蹈"),
        .init(id: 4, name: "游戏"),
        .init(id: 36, name: "知识"),
        .init(id: 188, name: "科技"),
        .init(id: 234, name: "运动"),
        .init(id: 223, name: "汽车"),
        .init(id: 160, name: "生活"),
        .init(id: 211, name: "美食"),
        .init(id: 217, name: "动物圈"),
        .init(id: 119, name: "鬼畜"),
        .init(id: 155, name: "时尚"),
        .init(id: 202, name: "资讯"),
        .init(id: 5, name: "娱乐"),
        .init(id: 181, name: "影视"),
        .init(id: 177, name: "纪录片")
    ]

    @State private var selected = 0
    @State private var videos: [VideoCard] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "排行榜", subtitle: "每日更新的全站排行") {
                    PlainIconButton(systemName: "arrow.clockwise", action: {
                        Task { await load() }
                    }, help: "刷新排行榜")
                }
                .padding(.bottom, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(categories) { category in
                            PillTabButton(title: category.name, selected: selected == category.id) {
                                selected = category.id
                                Task { await load() }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .padding(.bottom, 10)

                if isLoading && videos.isEmpty {
                    LoadingStateView()
                } else if let errorMessage, videos.isEmpty {
                    ErrorStateView(message: errorMessage) { Task { await load() } }
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                            VideoRowView(video: video,
                                         rank: index + 1,
                                         onOpen: { app.play(video: video) },
                                         onOpenUp: {
                                             if let mid = video.upMid { app.navigate(.space(mid)) }
                                         })
                        }
                    }
                }
            }
            .padding(Metrics.contentPadding)
        }
        .background(Palette.bg)
        .task { if videos.isEmpty { await load() } }
        .onChange(of: app.refreshToken) { _, _ in Task { await load() } }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            videos = try await BiliAPI.ranking(rid: selected)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
