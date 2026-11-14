import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 主窗口注册

/// 把 MainView 所在的窗口注册给 AppDelegate，用于关闭时隐藏、点击 Dock 重新显示。
struct MainWindowBinder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        BinderView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class BinderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async {
                AppDelegate.shared?.registerMainWindow(window)
            }
        }
    }
}

// MARK: - 窗口拖动

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var acceptsFirstResponder: Bool { false }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - 图片另存

enum ImageSaveResult {
    case saved
    case cancelled
    case failed
}

enum ImageSaver {
    /// 下载原图后弹出系统保存面板，由用户选择存储位置并保存为 PNG。
    @MainActor
    static func save(urlString: String, suggestedName: String) async -> ImageSaveResult {
        guard let url = URL(string: urlString) else { return .failed }
        var request = URLRequest(url: url)
        request.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = NSImage(data: data) else {
            return .failed
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let destination = panel.url else { return .cancelled }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return .failed
        }
        return (try? png.write(to: destination)) != nil ? .saved : .failed
    }

    /// 根据图片地址生成默认文件名。
    static func fileName(for urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "图片.png" }
        let base = url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? "图片.png" : "\(base).png"
    }

    /// 表情的默认文件名：[doge] → doge.png。
    static func emoteFileName(_ token: String) -> String {
        let name = token.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return name.isEmpty ? "表情.png" : "\(name).png"
    }
}

// MARK: - 图片

struct RemoteImage: View {
    let url: String
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Palette.bgRegular
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo")
                    .font(.ui(18))
                    .foregroundStyle(Palette.text3)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipped()
        .task(id: url) {
            failed = false
            image = nil
            guard !url.isEmpty else {
                failed = true
                return
            }
            image = await ImageLoader.shared.load(url)
            failed = image == nil
        }
    }
}

struct AvatarView: View {
    let url: String
    var size: CGFloat = 36

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Palette.bgRegular
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.ui(size * 0.45))
                    .foregroundStyle(Palette.text3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Palette.line, lineWidth: 0.8))
        .task(id: url) {
            guard !url.isEmpty else {
                image = nil
                return
            }
            image = await ImageLoader.shared.load(url)
        }
    }
}

// MARK: - 标签与按钮

struct DurationBadge: View {
    let seconds: Int
    var text: String?

    var body: some View {
        Text(text ?? Fmt.duration(seconds))
            .font(.ui(11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct CornerBadge: View {
    let text: String
    var color: Color = Palette.pink

    var body: some View {
        Text(text)
            .font(.ui(11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct PillTabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.pink : Palette.text2)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(selected ? Palette.pink.opacity(0.12) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct PlainIconButton: View {
    let systemName: String
    let action: () -> Void
    var help: String = ""

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.ui(14, weight: .medium))
                .foregroundStyle(hovering ? Palette.pink : Palette.text2)
                .frame(width: 30, height: 30)
                .background(hovering ? Palette.hover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - 页面标题

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.ui(22, weight: .semibold))
                    .foregroundStyle(Palette.text1)
                if let subtitle {
                    Text(subtitle)
                        .font(.ui(12))
                        .foregroundStyle(Palette.text3)
                }
            }
            Spacer()
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

// MARK: - 状态视图

struct LoadingStateView: View {
    var text: String = "加载中…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(text)
                .font(.ui(13))
                .foregroundStyle(Palette.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(80)
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.ui(40))
                .foregroundStyle(Palette.text3)
            Text(message)
                .font(.ui(13))
                .foregroundStyle(Palette.text2)
            if let retry {
                Button("重新加载", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.pink)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(80)
    }
}

struct LoginPromptView: View {
    let title: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.ui(46))
                .foregroundStyle(Palette.text3)
            Text(title)
                .font(.ui(14))
                .foregroundStyle(Palette.text2)
            Button {
                action()
            } label: {
                Text("扫码登录")
                    .font(.ui(13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                    .background(Palette.pink)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(80)
    }
}

// MARK: - 视频卡片

struct VideoCardView: View {
    let video: VideoCard
    var showBadge: Bool = true
    let onOpen: () -> Void
    var onOpenUp: (() -> Void)?

    @EnvironmentObject private var app: AppState
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 用 Color.clear 决定布局尺寸、图片只作叠层：否则封面按原始 16:9 撑开，
            // 会溢出列宽压到相邻卡片上（表现为图片互相重叠）。
            Color.clear
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    RemoteImage(url: ImageURL.thumb(video.cover))
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .overlay(alignment: .topLeading) {
                    if showBadge, let badge = video.badge, !badge.isEmpty {
                        CornerBadge(text: badge, color: Palette.blue)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    DurationBadge(seconds: video.duration)
                        .padding(6)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.cardRadius)
                        .stroke(Palette.pink.opacity(hovering ? 0.6 : 0), lineWidth: 1)
                }

            Text(video.title)
                .font(.ui(14, weight: .medium))
                .foregroundStyle(Palette.text1)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "play.circle")
                    .font(.ui(11))
                    .foregroundStyle(Palette.text3)
                Text(video.upName.isEmpty ? "UP主" : video.upName)
                    .font(.ui(12))
                    .foregroundStyle(Palette.text3)
                    .lineLimit(1)
                Text("·")
                    .font(.ui(11))
                    .foregroundStyle(Palette.text3)
                Text(Fmt.count(video.views))
                    .font(.ui(12))
                    .foregroundStyle(Palette.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("播放", action: onOpen)
            Button("添加到稍后再看") { app.addToWatchLater(video) }
            Divider()
            Button("内容不感兴趣") { app.reportDislike(video, upOnly: false) }
            Button("不想看此 UP 主") { app.reportDislike(video, upOnly: true) }
            Divider()
            if let onOpenUp, let mid = video.upMid {
                Button("打开 UP 主空间（" + String(mid) + "）", action: onOpenUp)
            }
            Button("在浏览器打开") {
                if let url = URL(string: video.watchURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - 视频行

struct VideoRowView: View {
    let video: VideoCard
    var rank: Int?
    let onOpen: () -> Void
    var onOpenUp: (() -> Void)?

    @EnvironmentObject private var app: AppState
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let rank {
                Text(String(format: "%02d", rank))
                    .font(.ui(18, weight: .bold))
                    .foregroundStyle(rank <= 3 ? Palette.pink : Palette.text3)
                    .frame(width: 30, alignment: .leading)
                    .padding(.top, 4)
            }

            RemoteImage(url: ImageURL.thumb(video.cover, width: 320, height: 200))
                .frame(width: 168, height: 105)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .overlay(alignment: .bottomTrailing) {
                    DurationBadge(seconds: video.duration)
                        .padding(5)
                }

            VStack(alignment: .leading, spacing: 8) {
                Text(video.title)
                    .font(.ui(15, weight: .medium))
                    .foregroundStyle(hovering ? Palette.pink : Palette.text1)
                    .lineLimit(2)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text(video.upName)
                        .font(.ui(12))
                        .foregroundStyle(Palette.text3)
                    Text("\(Fmt.count(video.views)) 播放 · \(Fmt.count(video.danmaku)) 弹幕")
                        .font(.ui(12))
                        .foregroundStyle(Palette.text3)
                }
            }
            .padding(.vertical, 2)
            Spacer()
            Text(Fmt.relativeDate(video.pubdate))
                .font(.ui(12))
                .foregroundStyle(Palette.text3)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(height: 125)
        .background(hovering ? Palette.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("播放", action: onOpen)
            Button("添加到稍后再看") { app.addToWatchLater(video) }
            Divider()
            Button("内容不感兴趣") { app.reportDislike(video, upOnly: false) }
            Button("不想看此 UP 主") { app.reportDislike(video, upOnly: true) }
            Divider()
            if let onOpenUp {
                Button("打开 UP 主空间", action: onOpenUp)
            }
        }
    }
}

// MARK: - 直播卡片

struct LiveCardView: View {
    let room: LiveRoom
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 同视频卡片：封面只作叠层，避免按原始比例溢出列宽与相邻卡片重叠。
            Color.clear
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    RemoteImage(url: ImageURL.thumb(room.cover, width: 480, height: 270))
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.ui(10))
                        Text(Fmt.count(room.online))
                            .font(.ui(11, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(7)
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                        .frame(height: 56)
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.title)
                                    .font(.ui(13, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text("\(room.uname) · \(room.areaName)")
                                    .font(.ui(11))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                            }
                            .padding(9)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))

            HStack(spacing: 6) {
                AvatarView(url: room.face, size: 18)
                Text(room.uname)
                    .font(.ui(12))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                Spacer()
                Text(room.parentName)
                    .font(.ui(11))
                    .foregroundStyle(Palette.text3)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .opacity(hovering ? 0.92 : 1)
        .contextMenu {
            Button("观看直播", action: onOpen)
            Button("在浏览器打开") {
                if let url = URL(string: "https://live.bilibili.com/\(room.id)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - 番剧卡片

struct BangumiCardView: View {
    let item: BangumiItem
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: ImageURL.thumb(item.cover, width: 300, height: 400))
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .overlay(alignment: .topLeading) {
                    if !item.badge.isEmpty {
                        CornerBadge(text: item.badge)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !item.score.isEmpty {
                        Text(item.score)
                            .font(.ui(12, weight: .bold))
                            .foregroundStyle(Palette.pink)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }

            Text(item.title)
                .font(.ui(13, weight: .medium))
                .foregroundStyle(Palette.text1)
                .lineLimit(1)
            Text(item.indexShow.isEmpty ? item.subtitle : item.indexShow)
                .font(.ui(11))
                .foregroundStyle(Palette.text3)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .stroke(Palette.pink.opacity(hovering ? 0.5 : 0), lineWidth: 1)
                .offset(y: 0)
        }
    }
}

// MARK: - 网格

struct VideoGrid: View {
    let videos: [VideoCard]
    var minWidth: CGFloat = 230
    var openUp: ((Int) -> Void)?
    let onOpen: (VideoCard) -> Void

    @EnvironmentObject private var app: AppState

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minWidth, maximum: 420), spacing: 18, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(videos.filter { !app.isHidden($0) }) { video in
                VideoCardView(video: video,
                              onOpen: { onOpen(video) },
                              onOpenUp: openUp == nil ? nil : {
                                  if let mid = video.upMid { openUp?(mid) }
                              })
            }
        }
    }
}
