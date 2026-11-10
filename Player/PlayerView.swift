import SwiftUI
import AppKit

struct PlayerView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject private var recorder = LiveRecorder.shared

    @State private var isHovering = false
    @State private var isSeeking = false
    @State private var sliderValue: Double = 0
    @State private var showFullDescription = false
    @State private var downloadNotice: String?
    /// 视频播放时是否隐藏下方详情，仅保留播放区域。
    @State private var isDetailHidden = false

    private var controlsVisible: Bool {
        isHovering || !viewModel.isPlaying || viewModel.isLoading
    }

    /// 直播弹幕侧栏宽度（右侧显示时）。
    private static let chatPanelWidth: CGFloat = 320

    var body: some View {
        GeometryReader { proxy in
            let chatOnRight = viewModel.showsLiveChat && viewModel.liveChatPlacement == .right
            let chatHidden = viewModel.showsLiveChat && viewModel.liveChatPlacement == .hidden
            let videoWidth = chatOnRight
                ? max(320, proxy.size.width - Self.chatPanelWidth)
                : proxy.size.width
            // 右侧显示、隐藏弹幕或隐藏详情时，画面区域铺满窗口，不留下方占位。
            let hidesDetail = !viewModel.showsLiveChat && isDetailHidden
            let fillsHeight = chatOnRight || chatHidden || hidesDetail
            let playerHeight = fillsHeight
                ? proxy.size.height
                : min(videoWidth * 9.0 / 16.0, max(280, proxy.size.height * 0.66))
            VStack(spacing: 0) {
                if chatOnRight {
                    HStack(spacing: 0) {
                        playerArea
                            .frame(width: videoWidth)
                        Rectangle()
                            .fill(Palette.line)
                            .frame(width: 1)
                        liveChatPanel
                            .frame(width: Self.chatPanelWidth)
                    }
                    .frame(width: proxy.size.width, height: playerHeight)
                } else {
                    playerArea
                        .frame(width: proxy.size.width, height: playerHeight)
                    if viewModel.showsLiveChat {
                        if viewModel.liveChatPlacement == .bottom {
                            liveChatPanel
                        }
                    } else if !isDetailHidden {
                        detailPanel
                    }
                }
            }
        }
        .background(Palette.bg)
        .preferredColorScheme(app.themeMode.colorScheme)
        .task { await viewModel.load() }
        .onDisappear { viewModel.stop() }
    }

    // MARK: - 播放区

    private var playerArea: some View {
        ZStack {
            Color.black

            VideoSurface(player: viewModel.player)

            if app.danmakuEnabled, !viewModel.danmakuItems.isEmpty {
                DanmakuOverlay(items: viewModel.danmakuItems,
                               time: viewModel.currentTime,
                               opacity: app.danmakuOpacity,
                               fontSize: app.danmakuFontSize)
            }

            if viewModel.isLoading || (viewModel.isLive && !viewModel.liveFrameReady && viewModel.errorMessage == nil) {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(viewModel.isLive ? "正在加载直播画面…" : "加载视频中…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Palette.pink)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await viewModel.retry() }
                    } label: {
                        Text("重试")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 7)
                            .background(Palette.pink)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(30)
            }

            controlOverlay
                .opacity(controlsVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: controlsVisible)
                .allowsHitTesting(controlsVisible)

            if let downloadNotice {
                VStack {
                    Text(downloadNotice)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .clipShape(Capsule())
                        .padding(.top, 16)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            NSApp.keyWindow?.toggleFullScreen(nil)
        }
    }

    private var controlOverlay: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 8) {
                        if viewModel.isLive {
                            HStack(spacing: 4) {
                                Circle().fill(Palette.pink).frame(width: 6, height: 6)
                                Text("直播中")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Capsule())
                        }
                        Text(viewModel.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                }

            Spacer()

            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .frame(height: 92)
                .overlay(alignment: .bottom) {
                    controls
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.togglePlay()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            if !viewModel.showsLiveChat {
                Text(Fmt.duration(Int(viewModel.currentTime)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()

                Slider(value: Binding(get: {
                    isSeeking ? sliderValue : min(viewModel.currentTime, max(viewModel.duration, 1))
                }, set: { sliderValue = $0 }), in: 0...max(viewModel.duration, 1)) { editing in
                    isSeeking = editing
                    if !editing {
                        viewModel.seek(to: sliderValue)
                    }
                }
                .tint(Palette.pink)
                .controlSize(.small)

                Text(Fmt.duration(Int(viewModel.duration)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()
            } else {
                Text(viewModel.isRecordingPlayback ? "录制回放" : "直播画面")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
            }

            Button {
                app.danmakuEnabled.toggle()
            } label: {
                Image(systemName: app.danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(app.danmakuEnabled ? Palette.pink : .white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("弹幕开关")

            if viewModel.showsLiveChat {
                Menu {
                    ForEach(LiveChatPlacement.allCases) { placement in
                        Button {
                            viewModel.liveChatPlacement = placement
                        } label: {
                            if placement == viewModel.liveChatPlacement {
                                Label(placement.title, systemImage: "checkmark")
                            } else {
                                Label(placement.title, systemImage: placement.icon)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.rightthird.inset.filled")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("弹幕列表位置")
            }

            if viewModel.isLive {
                let recording = recorder.isRecording(owner: viewModel.recordingOwner)
                Button {
                    Task { await viewModel.toggleRecording() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: recording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 15, weight: .medium))
                        if recording {
                            Text(Fmt.duration(Int(recorder.elapsed(for: viewModel.recordingOwner))))
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(recording ? Palette.pink : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(recording ? "停止录制" : "录制直播")

                qualityMenu {
                    Text(qualityTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            } else if !viewModel.isRecordingPlayback {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isDetailHidden.toggle() }
                } label: {
                    Image(systemName: isDetailHidden
                          ? "rectangle.inset.filled"
                          : "rectangle.bottomthird.inset.filled")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(isDetailHidden ? "显示详情" : "隐藏详情，仅显示播放区域")

                speedMenu {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                }

                qualityMenu {
                    Text(qualityTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }

                if !viewModel.audioQualityTitle.isEmpty {
                    Text(viewModel.audioQualityTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.pink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.pink.opacity(0.16))
                        .clipShape(Capsule())
                }

                downloadMenu {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("全屏")
        }
    }

    private var qualityTitle: String {
        viewModel.qualities.first(where: { $0.id == viewModel.selectedQuality })?.title ?? "清晰度"
    }

    private func speedMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                Button {
                    viewModel.setRate(rate)
                } label: {
                    Text(rate == 1 ? "1.0x 倍速" : "\(rate)x 倍速")
                }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func qualityMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            if viewModel.qualities.isEmpty {
                Text("暂无可用清晰度")
            } else {
                ForEach(viewModel.qualities) { quality in
                    Button {
                        Task { await viewModel.selectQuality(quality.id) }
                    } label: {
                        Text(quality.title)
                    }
                }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - 下载

    private var downloadQualities: [QualityOption] {
        viewModel.qualities.isEmpty
            ? [QualityOption(id: viewModel.selectedQuality, title: qualityTitle)]
            : viewModel.qualities
    }

    private func downloadMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            ForEach(downloadQualities) { quality in
                Button {
                    startDownload(quality)
                } label: {
                    Text(quality.title)
                }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("下载视频")
    }

    private func startDownload(_ quality: QualityOption) {
        guard let source = viewModel.downloadSource else {
            showDownloadNotice("暂无可下载的视频信息")
            return
        }
        DownloadManager.shared.start(source: source,
                                     quality: quality.id,
                                     qualityTitle: quality.title,
                                     title: viewModel.title)
        showDownloadNotice("已开始下载：\(quality.title)")
    }

    private func showDownloadNotice(_ text: String) {
        downloadNotice = text
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if downloadNotice == text { downloadNotice = nil }
        }
    }

    // MARK: - 直播弹幕列表

    private var liveChatPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("弹幕")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text1)
                Text("\(viewModel.liveMessages.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(danmakuStatusColor)
                        .frame(width: 6, height: 6)
                    Text(danmakuStatusLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Rectangle()
                .fill(Palette.line)
                .frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if viewModel.liveMessages.isEmpty {
                            Text(danmakuStatusHint)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.text3)
                                .padding(.top, 8)
                        } else {
                            ForEach(viewModel.liveMessages) { message in
                                liveMessageText(message)
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
                .onChange(of: viewModel.liveMessages.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.bg)
    }

    private var danmakuStatusColor: Color {
        if viewModel.isRecordingPlayback { return Palette.pink }
        switch viewModel.liveDanmakuStatus {
        case .connecting: return Palette.text3
        case .connected: return Palette.pink
        case .failed: return .orange
        case .closed: return Palette.text3
        }
    }

    private var danmakuStatusLabel: String {
        if viewModel.isRecordingPlayback { return "弹幕回放" }
        switch viewModel.liveDanmakuStatus {
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .failed: return "连接失败"
        case .closed: return "已断开"
        }
    }

    private var danmakuStatusHint: String {
        if viewModel.isRecordingPlayback { return "录制弹幕会随播放进度同步显示" }
        switch viewModel.liveDanmakuStatus {
        case .connecting: return "正在连接弹幕…"
        case .connected: return "已连接弹幕服务器，等待新弹幕…"
        case .failed(let reason): return "弹幕连接失败：\(reason)"
        case .closed: return "弹幕已断开"
        }
    }

    /// 昵称 + 完整弹幕内容；昵称用弱化色，正文沿用弹幕颜色。
    private func liveMessageText(_ message: LiveDanmakuMessage) -> Text {
        let content = Text(message.text).foregroundStyle(readableColor(message.color))
        guard !message.nickname.isEmpty else { return content }
        return Text("\(message.nickname)：").foregroundStyle(Palette.text3) + content
    }

    /// 弹幕白色文字在浅色背景上不可读，亮色时改用正文色。
    private func readableColor(_ color: NSColor) -> Color {
        guard let rgb = color.usingColorSpace(.sRGB) else { return Palette.text1 }
        let luminance = 0.3 * rgb.redComponent + 0.59 * rgb.greenComponent + 0.11 * rgb.blueComponent
        return luminance > 0.85 ? Palette.text1 : Color(nsColor: color)
    }

    // MARK: - 详情

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(viewModel.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.text1)
                    .textSelection(.enabled)

                HStack(spacing: 16) {
                    Label("\(Fmt.count(viewModel.views)) 播放", systemImage: "play.rectangle")
                    Label("\(Fmt.count(viewModel.danmakuCount)) 弹幕", systemImage: "text.bubble")
                    if viewModel.pubdate > 0 {
                        Label(Fmt.fullDate(viewModel.pubdate), systemImage: "calendar")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.text3)

                if !viewModel.isLive {
                    HStack(spacing: 10) {
                        AvatarView(url: ImageURL.thumb(viewModel.upFace, width: 96, height: 96), size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.upName.isEmpty ? "哔哩哔哩" : viewModel.upName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Palette.text1)
                            if let mid = viewModel.upMid {
                                Text(verbatim: "UID \(mid)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.text3)
                            }
                            if !viewModel.upLocation.isEmpty {
                                Text(viewModel.upLocation)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.text3)
                            }
                        }
                        Spacer()
                        if let mid = viewModel.upMid {
                            Button {
                                app.navigate(.space(mid))
                            } label: {
                                Text("UP 主空间")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.pink)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Palette.pink.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if viewModel.pages.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(viewModel.pages.enumerated()), id: \.element.id) { index, page in
                                Button {
                                    Task { await viewModel.playPage(index: index) }
                                } label: {
                                    Text("P\(index + 1) \(page.part ?? "")")
                                        .font(.system(size: 11))
                                        .foregroundStyle(index == viewModel.currentPageIndex ? Palette.pink : Palette.text2)
                                        .lineLimit(1)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(index == viewModel.currentPageIndex ? Palette.pink.opacity(0.12) : Palette.bgThin)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !viewModel.seasonEpisodes.isEmpty {
                    seasonSection
                } else if !viewModel.isLive, !viewModel.isRecordingPlayback {
                    videoActionsRow
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.bgThin)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if !viewModel.desc.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.desc)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.text2)
                            .lineSpacing(3)
                            .lineLimit(showFullDescription ? nil : 4)
                            .textSelection(.enabled)
                        Button(showFullDescription ? "收起" : "展开更多") {
                            showFullDescription.toggle()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.text3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.bgThin)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if viewModel.isLive {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(Palette.pink)
                        Text("正在直播中，弹幕与评论请在网页端查看")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.text2)
                    }
                    .padding(12)
                    .background(Palette.bgThin)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Divider().overlay(Palette.line)
                    commentsSection
                }
            }
            .padding(24)
        }
        .background(Palette.bg)
    }

    /// 当前视频在合集中的位置（从 1 开始），不在合集内为 0。
    private var currentSeasonIndex: Int {
        guard let aid = viewModel.currentSeasonAid,
              let index = viewModel.seasonEpisodes.firstIndex(where: { $0.aid == aid }) else { return 0 }
        return index + 1
    }

    /// 合集：左侧视频信息与互动按钮，右侧合集内视频列表。
    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(viewModel.seasonTitle.isEmpty ? "合集" : viewModel.seasonTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text1)
                    .lineLimit(1)
                Text("(\(currentSeasonIndex)/\(viewModel.seasonEpisodes.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
                Spacer()
                if viewModel.seasonViews > 0 {
                    Label("\(Fmt.count(viewModel.seasonViews)) 播放", systemImage: "play.rectangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.text3)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                seasonInfoPane
                    .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(Palette.line)
                    .frame(width: 1)
                    .frame(maxHeight: 250)

                seasonListPane
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Palette.bgThin)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 左半：封面、标题、UP 主、数据与互动按钮。
    private var seasonInfoPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                RemoteImage(url: viewModel.cover)
                    .frame(width: 120, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 5) {
                    Text(viewModel.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.text1)
                        .lineLimit(2)
                    Text(viewModel.upName)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                    HStack(spacing: 10) {
                        statLabel("play.rectangle", Fmt.count(viewModel.views))
                        statLabel("text.bubble", Fmt.count(viewModel.danmakuCount))
                        statLabel("hand.thumbsup", Fmt.count(viewModel.likeCount))
                    }
                }
            }

            videoActionsRow
        }
    }

    /// 点赞 / 不喜欢 / 投币 / 收藏，合集与非合集视频通用。
    private var videoActionsRow: some View {
        HStack(spacing: 8) {
            actionButton(icon: viewModel.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                         count: viewModel.likeCount,
                         active: viewModel.isLiked) {
                guard requireLogin() else { return }
                Task { await viewModel.toggleLike() }
            }
            actionButton(icon: "hand.thumbsdown",
                         count: nil,
                         active: viewModel.isDisliked) {
                guard requireLogin() else { return }
                Task { await viewModel.dislike() }
            }
            actionButton(icon: "bitcoinsign.circle",
                         count: viewModel.coinCount,
                         active: viewModel.coinsGiven > 0) {
                guard requireLogin() else { return }
                Task { await viewModel.addCoin() }
            }
            actionButton(icon: viewModel.isFavorited ? "star.fill" : "star",
                         count: viewModel.favoriteCount,
                         active: viewModel.isFavorited) {
                guard requireLogin() else { return }
                Task { await viewModel.toggleFavorite(userMid: app.user?.mid) }
            }
            ShareLink(item: viewModel.shareText) {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(.system(size: 12, weight: .medium))
                    Text("转发")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Palette.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.bg)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("转发给朋友")
        }
    }

    /// 右半：合集内视频列表。
    private var seasonListPane: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(viewModel.seasonEpisodes.enumerated()), id: \.offset) { index, episode in
                    seasonRow(episode, index: index)
                }
            }
        }
        .frame(maxHeight: 250)
    }

    private func statLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10))
        }
        .foregroundStyle(Palette.text3)
    }

    private func actionButton(icon: String, count: Int?, active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                if let count {
                    Text(Fmt.count(count))
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(active ? Palette.pink : Palette.text2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(active ? Palette.pink.opacity(0.12) : Palette.bg)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func requireLogin() -> Bool {
        guard BiliClient.shared.isLoggedIn else {
            app.showLogin = true
            return false
        }
        return true
    }

    private func seasonRow(_ episode: UgcEpisode, index: Int) -> some View {
        let isCurrent = episode.aid == viewModel.currentSeasonAid
        return Button {
            Task { await viewModel.playSeasonEpisode(episode) }
        } label: {
            HStack(spacing: 8) {
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.pink)
                }
                Text(episode.title ?? episode.arc?.title ?? "第 \(index + 1) 集")
                    .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
                    .foregroundStyle(isCurrent ? Palette.pink : Palette.text2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.duration(episode.arc?.duration ?? episode.page?.duration ?? 0))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? Palette.pink.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var commentsSection: some View {
        HStack(spacing: 8) {
            Text("评论")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text1)
            Text(Fmt.count(viewModel.repliesCount))
                .font(.system(size: 11))
                .foregroundStyle(Palette.text3)
            if viewModel.isLoadingComments {
                ProgressView().controlSize(.mini)
            }
        }

        if viewModel.comments.isEmpty {
            Text(viewModel.isLoadingComments ? "正在加载评论…" : "暂无评论")
                .font(.system(size: 12))
                .foregroundStyle(Palette.text3)
                .padding(.vertical, 16)
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(viewModel.comments) { reply in
                    HStack(alignment: .top, spacing: 10) {
                        AvatarView(url: ImageURL.thumb(reply.member?.avatar, width: 64, height: 64), size: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(reply.member?.uname ?? "")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Palette.text2)
                                Text(Fmt.relativeDate(reply.ctime ?? 0))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.text3)
                                if let location = reply.location {
                                    Text(location)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Palette.text3)
                                }
                            }
                            Text(reply.content?.message ?? "")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.text1)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                            HStack(spacing: 4) {
                                Image(systemName: "hand.thumbsup")
                                Text(Fmt.count(reply.like ?? 0))
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.text3)
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}
