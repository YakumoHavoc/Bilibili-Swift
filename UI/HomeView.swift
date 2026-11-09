import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppState

    @State private var videos: [VideoCard] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var freshIndex = 1
    @State private var canLoadMore = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "推荐", subtitle: "为你精选的优质内容") {
                    PlainIconButton(systemName: "arrow.clockwise", action: {
                        Task { await reload() }
                    }, help: "刷新推荐")
                }
                .padding(.bottom, 16)

                if isLoading && videos.isEmpty {
                    LoadingStateView()
                } else if let errorMessage, videos.isEmpty {
                    ErrorStateView(message: errorMessage) {
                        Task { await reload() }
                    }
                } else {
                    VideoGrid(videos: videos, openUp: { mid in
                        app.navigate(.space(mid))
                    }, onOpen: { video in
                        app.play(video: video)
                    })

                    if isLoadingMore {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(20)
                    } else if canLoadMore {
                        Color.clear
                            .frame(height: 2)
                            .onAppear {
                                Task { await loadMore() }
                            }
                    } else {
                        Text("已经到底啦 ~")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.text3)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                }
            }
            .padding(Metrics.contentPadding)
        }
        .background(Palette.bg)
        .task {
            if videos.isEmpty { await reload() }
        }
        .onChange(of: app.refreshToken) { _, _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        freshIndex = 1
        do {
            let items = try await BiliAPI.recommend(freshIndex: 1)
            videos = items
            freshIndex = 2
            canLoadMore = !items.isEmpty
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading, !isLoadingMore, canLoadMore else { return }
        isLoadingMore = true
        do {
            let items = try await BiliAPI.recommend(freshIndex: freshIndex)
            let known = Set(videos.map(\.id))
            videos += items.filter { !known.contains($0.id) }
            freshIndex += 1
            canLoadMore = !items.isEmpty
        } catch {
            canLoadMore = false
        }
        isLoadingMore = false
    }
}
