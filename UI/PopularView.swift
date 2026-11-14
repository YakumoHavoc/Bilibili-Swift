import SwiftUI

struct PopularView: View {
    @EnvironmentObject private var app: AppState

    @State private var videos: [VideoCard] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var canLoadMore = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "热门", subtitle: "当前全站最热门的视频") {
                    HStack(spacing: 6) {
                        Button {
                            app.navigate(.ranking)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chart.bar.fill")
                                Text("排行榜")
                            }
                            .font(.ui(12, weight: .medium))
                            .foregroundStyle(Palette.pink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Palette.pink.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        PlainIconButton(systemName: "arrow.clockwise", action: {
                            Task { await reload() }
                        }, help: "刷新热门")
                    }
                }
                .padding(.bottom, 8)

                if isLoading && videos.isEmpty {
                    LoadingStateView()
                } else if let errorMessage, videos.isEmpty {
                    ErrorStateView(message: errorMessage) {
                        Task { await reload() }
                    }
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
                    .padding(.top, 4)

                    if isLoadingMore {
                        ProgressView().controlSize(.small).padding(18)
                    } else if canLoadMore {
                        Color.clear.frame(height: 2).onAppear {
                            Task { await loadMore() }
                        }
                    }
                }
            }
            .padding(Metrics.contentPadding)
        }
        .background(Palette.bg)
        .task { if videos.isEmpty { await reload() } }
        .onChange(of: app.refreshToken) { _, _ in Task { await reload() } }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        page = 1
        do {
            let items = try await BiliAPI.popular(page: 1)
            videos = items
            page = 2
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
            let items = try await BiliAPI.popular(page: page)
            videos += items
            page += 1
            canLoadMore = !items.isEmpty
        } catch {
            canLoadMore = false
        }
        isLoadingMore = false
    }
}
