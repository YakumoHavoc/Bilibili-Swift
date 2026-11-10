import SwiftUI
import AppKit

enum Page: Hashable {
    case home
    case popular
    case ranking
    case live
    case bangumi
    case cinema
    case dynamic
    case favorites
    case downloads
    case recordings
    case mine(MineTab)
    case settings
    case search(String)
    case space(Int)
}

enum MineTab: String, CaseIterable, Identifiable {
    case history
    case favorite
    case watchLater

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "历史记录"
        case .favorite: return "我的收藏"
        case .watchLater: return "稍后再看"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var page: Page = .home
    @Published var refreshToken = 0
    @Published var user: UserProfile?
    @Published var showLogin = false
    @Published var toast: String?

    /// 已反馈「不感兴趣」的视频，以及已反馈「不想看此 UP 主」的 mid，仅本机内存生效。
    @Published private(set) var hiddenVideoIDs: Set<String> = []
    @Published private(set) var hiddenUpMids: Set<Int> = []

    @Published var themeMode: ThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: "app.theme") }
    }

    @Published var playQuality: Int {
        didSet { UserDefaults.standard.set(playQuality, forKey: "player.quality") }
    }
    @Published var danmakuEnabled: Bool {
        didSet { UserDefaults.standard.set(danmakuEnabled, forKey: "player.danmaku") }
    }
    @Published var danmakuOpacity: Double {
        didSet { UserDefaults.standard.set(danmakuOpacity, forKey: "player.danmakuOpacity") }
    }
    @Published var danmakuFontSize: Double {
        didSet { UserDefaults.standard.set(danmakuFontSize, forKey: "player.danmakuFontSize") }
    }

    private var backStack: [Page] = []

    init() {
        let themeRaw = UserDefaults.standard.string(forKey: "app.theme") ?? ThemeMode.system.rawValue
        themeMode = ThemeMode(rawValue: themeRaw) ?? .system
        let quality = UserDefaults.standard.object(forKey: "player.quality") as? Int ?? 80
        playQuality = quality
        let danmaku = UserDefaults.standard.object(forKey: "player.danmaku") as? Bool ?? true
        danmakuEnabled = danmaku
        let opacity = UserDefaults.standard.object(forKey: "player.danmakuOpacity") as? Double ?? 0.9
        danmakuOpacity = opacity
        let fontSize = UserDefaults.standard.object(forKey: "player.danmakuFontSize") as? Double ?? 18
        danmakuFontSize = fontSize
    }

    func bootstrap() {
        Task {
            await BiliClient.shared.prepare()
            await refreshUser()
        }
    }

    func refreshUser() async {
        guard let nav = await BiliAPI.fetchNav() else {
            user = nil
            return
        }
        user = UserProfile(mid: nav.mid ?? 0,
                           name: nav.uname ?? "",
                           face: ImageURL.fix(nav.face),
                           level: nav.level_info?.current_level ?? 0,
                           isVIP: (nav.vipStatus ?? 0) == 1,
                           signature: nav.signature ?? "")
    }

    func logout() {
        BiliClient.shared.clearLoginCookies()
        user = nil
        showToast("已退出登录")
    }

    func navigate(_ target: Page, pushBack: Bool = true) {
        if pushBack, target != page {
            backStack.append(page)
            if backStack.count > 30 { backStack.removeFirst() }
        }
        page = target
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        page = previous
    }

    func search(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        navigate(.search(trimmed))
    }

    func play(video: VideoCard) {
        let identifier = video.bvid ?? video.aid.map { "av\($0)" }
        guard let identifier else {
            showToast("无法播放该视频")
            return
        }
        PlayerWindowController.shared.open(identifier: identifier,
                                           title: video.title,
                                           app: self)
    }

    func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == message { toast = nil }
        }
    }

    /// 把列表里的视频加入稍后再看。
    func addToWatchLater(_ video: VideoCard) {
        guard BiliClient.shared.isLoggedIn else {
            showLogin = true
            return
        }
        guard let aid = video.aid else {
            showToast("无法添加到稍后再看")
            return
        }
        Task {
            do {
                let code = try await BiliAPI.addWatchLater(aid: aid)
                guard code == 0 else {
                    showToast("添加失败（\(code)）")
                    return
                }
                showToast("已添加到稍后再看")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    // MARK: - 推荐反馈

    /// 该视频是否已被本机隐藏（不感兴趣或不想看此 UP 主）。
    func isHidden(_ video: VideoCard) -> Bool {
        if let mid = video.upMid, hiddenUpMids.contains(mid) { return true }
        return hiddenVideoIDs.contains(video.id)
    }

    /// 对列表卡片反馈：内容不感兴趣 / 不想看此 UP 主。
    func reportDislike(_ video: VideoCard, upOnly: Bool) {
        guard BiliClient.shared.isLoggedIn else {
            showLogin = true
            return
        }
        guard let aid = video.aid else {
            showToast("无法获取该视频信息")
            return
        }
        Task {
            await reportDislike(aid: aid, upMid: video.upMid, videoID: video.id, upOnly: upOnly)
        }
    }

    /// 对当前播放的视频反馈：内容不感兴趣 / 不想看此 UP 主。
    func reportDislike(aid: Int, upMid: Int?, videoID: String, upOnly: Bool) async {
        guard BiliClient.shared.isLoggedIn else {
            showLogin = true
            return
        }
        do {
            let code = try await BiliAPI.feedbackDislike(aid: aid,
                                                         upMid: upMid ?? 0,
                                                         reasonID: upOnly ? 4 : 1)
            guard code == 0 else {
                showToast("反馈失败（\(code)）")
                return
            }
        } catch {
            showToast("反馈失败：\(error.localizedDescription)")
            return
        }
        if upOnly, let upMid {
            hiddenUpMids.insert(upMid)
        } else {
            hiddenVideoIDs.insert(videoID)
        }
        showToast(upOnly ? "已减少该 UP 主的推荐" : "已反馈，将减少类似内容")
    }
}
