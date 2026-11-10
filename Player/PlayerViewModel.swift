import Foundation
import AVFoundation
import AppKit

enum PlaybackMode: Equatable {
    case video(identifier: String)
    case episode(epID: Int)
    case live(roomID: Int)
    case recording(LiveRecording)
}

struct QualityOption: Identifiable, Hashable {
    let id: Int
    let title: String
}

/// 直播弹幕列表的显示位置。
enum LiveChatPlacement: String, CaseIterable, Identifiable {
    case bottom
    case right
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return "下方显示"
        case .right: return "右侧显示"
        case .hidden: return "隐藏"
        }
    }

    var icon: String {
        switch self {
        case .bottom: return "rectangle.split.1x2"
        case .right: return "rectangle.split.2x1"
        case .hidden: return "eye.slash"
        }
    }

    private static let key = "liveChatPlacement"

    static var saved: LiveChatPlacement {
        UserDefaults.standard.string(forKey: key).flatMap(LiveChatPlacement.init(rawValue:)) ?? .bottom
    }

    static func save(_ placement: LiveChatPlacement) {
        UserDefaults.standard.set(placement.rawValue, forKey: key)
    }
}

struct DanmakuLaneItem: Identifiable {
    let id: Int
    let item: DanmakuItem
    let lane: Int
    let color: NSColor
}

struct LiveDanmakuMessage: Identifiable {
    let id: Int
    let nickname: String
    let text: String
    let color: NSColor
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var title: String
    @Published var upName = ""
    @Published var upFace = ""
    @Published var upMid: Int?
    @Published var cover = ""
    @Published var desc = ""
    @Published var views = 0
    @Published var danmakuCount = 0
    @Published var pubdate = 0
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var isPlaying = false {
        didSet {
            if isPlaying != oldValue { updateSleepAssertion() }
        }
    }
    @Published var isLive = false
    @Published var currentTime: Double = 0 {
        didSet {
            if isRecordingPlayback { syncReplayDanmaku() }
        }
    }
    @Published var duration: Double = 0
    @Published var qualities: [QualityOption] = []
    @Published var selectedQuality: Int
    /// 当前音轨的音质说明（Hi-Res 无损 / 杜比全景声）。
    @Published var audioQualityTitle = ""
    /// UP 主的 IP 属地：优先取本人评论，其次空间页的所在地。
    @Published var upLocation = ""
    /// 视频所属合集的标题、播放量与视频列表。
    @Published var seasonTitle = ""
    @Published var seasonViews = 0
    @Published var seasonEpisodes: [UgcEpisode] = []
    /// 当前播放视频在合集内的 aid，用于高亮。
    @Published var currentSeasonAid: Int?
    /// 互动数据与当前账号的互动状态。
    @Published var likeCount = 0
    @Published var coinCount = 0
    @Published var favoriteCount = 0
    @Published var isLiked = false
    @Published var isDisliked = false
    @Published var isFavorited = false
    @Published var coinsGiven = 0
    /// 收藏时使用的收藏夹 id，首次操作时获取。
    private var favoriteFolderID: Int?
    @Published var playbackRate: Double = 1
    @Published var danmakuItems: [DanmakuLaneItem] = []
    @Published var liveMessages: [LiveDanmakuMessage] = []
    @Published var comments: [Reply] = []
    @Published var repliesCount = 0
    @Published var pages: [VideoPage] = []
    @Published var currentPageIndex = 0
    @Published var isLoadingComments = false
    @Published var isBuffering = false
    @Published var liveDanmakuStatus: LiveDanmakuStatus = .connecting
    @Published var liveFrameReady = false
    /// 直播中的房间号；录制回放时为 nil。
    @Published var liveRoomID: Int?
    /// 正在播放本地录制的直播回放。
    @Published var isRecordingPlayback = false
    /// 直播弹幕列表的显示位置，记忆上次选择。
    @Published var liveChatPlacement: LiveChatPlacement = LiveChatPlacement.saved {
        didSet { LiveChatPlacement.save(liveChatPlacement) }
    }

    let player = AVPlayer()
    let mode: PlaybackMode
    /// 每个播放窗口独立的录制标识，多个直播窗口可各自录制互不影响。
    let recordingOwner = UUID()

    private var cid: Int?
    private var aid: Int?
    private var bvid: String?
    private var episodeID: Int?
    private var referer = "https://www.bilibili.com/"
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// 播放期间阻止屏幕息屏与系统待机。
    private var sleepActivity: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var failedObserver: NSObjectProtocol?
    private var suppressSeekUpdate = false
    /// 当前播放项使用的 DASH 资源加载器，需与播放项同生命周期持有。
    private var dashLoaders: [DashResourceLoader] = []
    private var liveDanmaku: LiveDanmakuClient?
    private var liveDanmakuSeq = 0
    private var nextLiveLane = 0
    private var liveStart = Date()
    private var currentLiveURL: URL?
    private var replayDanmaku: [RecordedDanmaku] = []
    private var replayCursor = 0
    private var replaySeq = 0
    /// 每次开播自增；旧的开播流程（预滚回调）据此失效，避免切歌后误播。
    private var playGeneration = 0
    /// 定时上报观看进度到账号历史记录。
    private var historyTask: Task<Void, Never>?

    init(mode: PlaybackMode, title: String, quality: Int) {
        self.mode = mode
        self.title = title
        self.selectedQuality = quality
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 1.0

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.03, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // 观察者固定在主队列回调，用 assumeIsolated 明确隔离域，避免并发告警。
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isLive {
                    self.currentTime = Date().timeIntervalSince(self.liveStart)
                    if !self.liveFrameReady, time.seconds.isFinite, time.seconds > 0.05 {
                        self.liveFrameReady = true
                    }
                } else {
                    let seconds = time.seconds
                    if seconds.isFinite, !self.suppressSeekUpdate {
                        self.currentTime = seconds
                    }
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }

        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }

        // 播放器真正停止（暂停、播放结束、直播断流且不再播放）时立即释放待机阻止。
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateSleepAssertion()
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failedObserver {
            NotificationCenter.default.removeObserver(failedObserver)
        }
    }

    // MARK: - 加载

    func load() async {
        isLoading = true
        errorMessage = nil
        upLocation = ""

        do {
            switch mode {
            case .video(let identifier):
                try await loadVideo(identifier: identifier)
            case .episode(let epID):
                try await loadEpisode(epID: epID)
            case .live(let roomID):
                try await loadLive(roomID: roomID)
            case .recording(let recording):
                try await loadRecording(recording)
            }
            isLoading = false
            // 视频/番剧播放时定时把进度写入账号历史记录。
            if !isLive, !isRecordingPlayback {
                startHistoryReporting()
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func retry() async {
        player.pause()
        isPlaying = false
        await load()
    }

    private func loadVideo(identifier: String) async throws {
        let detail = try await BiliAPI.videoDetail(identifier: identifier)
        bvid = detail.bvid
        aid = detail.aid
        cid = detail.cid
        title = detail.title ?? title
        cover = ImageURL.fix(detail.pic)
        desc = detail.desc ?? ""
        upName = detail.owner?.name ?? ""
        upFace = ImageURL.fix(detail.owner?.face)
        upMid = detail.owner?.mid
        views = detail.stat?.view ?? 0
        danmakuCount = detail.stat?.danmaku ?? 0
        likeCount = detail.stat?.like ?? 0
        coinCount = detail.stat?.coin ?? 0
        favoriteCount = detail.stat?.favorite ?? 0
        isLiked = false
        isDisliked = false
        isFavorited = false
        coinsGiven = 0
        favoriteFolderID = nil
        pubdate = detail.pubdate ?? 0
        pages = detail.pages ?? []
        currentPageIndex = 0
        referer = "https://www.bilibili.com/video/\(detail.bvid ?? identifier)/"

        // 合集信息：用于在播放页列出同合集的其他视频。
        if let season = detail.ugc_season {
            seasonTitle = season.title ?? ""
            seasonViews = season.stat?.view ?? 0
            seasonEpisodes = season.sections?.flatMap { $0.episodes ?? [] } ?? []
            currentSeasonAid = detail.aid
        } else {
            seasonTitle = ""
            seasonViews = 0
            seasonEpisodes = []
            currentSeasonAid = nil
        }

        // 弹幕与评论不阻塞播放，后台并行加载。
        startAuxiliaryLoading(cid: cid)
        Task { @MainActor [weak self] in await self?.loadRelation() }

        try await refreshPlayURL()
    }

    private func loadEpisode(epID: Int) async throws {
        let season = try await BiliAPI.seasonInfo(epID: epID)
        guard let episode = season.episodes?.first(where: { $0.ep_id == epID }) ?? season.episodes?.first else {
            throw BiliError.decoding("未找到该剧集信息")
        }
        episodeID = episode.ep_id ?? epID
        bvid = episode.bvid
        aid = episode.aid
        cid = episode.cid
        upName = season.title ?? season.season_title ?? ""
        title = episode.long_title?.isEmpty == false ? "\(season.title ?? "") · \(episode.long_title ?? "")" : (season.title ?? title)
        cover = ImageURL.fix(episode.cover ?? season.cover)
        desc = season.evaluate ?? ""
        views = season.stat?.views ?? 0
        danmakuCount = season.stat?.danmakus ?? 0
        pubdate = episode.pub_time ?? 0
        referer = "https://www.bilibili.com/bangumi/play/ep\(episode.ep_id ?? epID)/"

        startAuxiliaryLoading(cid: cid)

        try await refreshPlayURL()
    }

    private func startAuxiliaryLoading(cid: Int?) {
        Task { [weak self] in
            guard let self else { return }
            if let cid {
                await self.loadDanmaku(cid: cid)
            }
            await self.loadComments()
        }
    }

    private func loadLive(roomID: Int) async throws {
        isLive = true
        isRecordingPlayback = false
        liveRoomID = roomID
        liveStart = Date()
        currentTime = 0
        danmakuItems = []
        liveMessages = []
        liveFrameReady = false
        referer = "https://live.bilibili.com/\(roomID)"
        connectLiveDanmaku(roomID: roomID)
        // 拉取历史弹幕，先铺满弹幕列表，避免进入房间后空白等待。
        Task { [weak self] in await self?.loadLiveHistory(roomID: roomID) }

        do {
            let info = try await BiliAPI.livePlayInfo(roomID: roomID, qn: selectedQuality)
            updateLiveQualities(from: info)
            // 同一房间有多个 CDN 节点，节点间速度差异很大；先探测再交给播放器，
            // 避免落到慢节点上长时间黑屏。
            let candidates = BiliAPI.liveStreamCandidates(from: info)
            guard let url = await pickLiveStreamURL(candidates) else {
                throw BiliError.decoding("该直播间暂时无法播放")
            }
            currentLiveURL = url
            let item = AVPlayerItem(asset: AVURLAsset(url: url, options: assetOptions()))
            // 直播分段为 4 秒，缓冲过小会一直卡在首帧；保持自动防卡顿并缓冲 2 秒。
            item.preferredForwardBufferDuration = 2
            player.automaticallyWaitsToMinimizeStalling = true
            player.replaceCurrentItem(with: item)
            startPlayback()
            isPlaying = true
            // 进入直播间后上报一次，写入直播观看记录（登录后生效）。
            Task { await BiliAPI.reportLiveEntry(roomID: roomID) }
        } catch {
            stop()
            throw error
        }
    }

    private func updateLiveQualities(from data: LivePlayInfoData) {
        let list = BiliAPI.liveQualities(from: data).map { QualityOption(id: $0.id, title: $0.title) }
        if !list.isEmpty {
            qualities = list
        }
        if let current = BiliAPI.liveCurrentQuality(from: data),
           list.contains(where: { $0.id == current }) {
            selectedQuality = current
        }
    }

    /// 切换直播清晰度：重新请求对应画质的播放地址并替换当前流。
    private func selectLiveQuality(_ quality: Int) async {
        guard let roomID = liveRoomID, quality != selectedQuality else { return }
        do {
            let info = try await BiliAPI.livePlayInfo(roomID: roomID, qn: quality)
            updateLiveQualities(from: info)
            let candidates = BiliAPI.liveStreamCandidates(from: info)
            guard let url = await pickLiveStreamURL(candidates) else {
                throw BiliError.decoding("该画质暂时不可用")
            }
            currentLiveURL = url
            let item = AVPlayerItem(asset: AVURLAsset(url: url, options: assetOptions()))
            item.preferredForwardBufferDuration = 2
            player.replaceCurrentItem(with: item)
            startPlayback()
            isPlaying = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 直播录制

    func toggleRecording() async {
        if LiveRecorder.shared.isRecording(owner: recordingOwner) {
            await LiveRecorder.shared.stop(owner: recordingOwner)
            return
        }
        guard let roomID = liveRoomID, let url = currentLiveURL else { return }
        LiveRecorder.shared.start(owner: recordingOwner,
                                  roomID: roomID,
                                  title: title,
                                  playlistURL: url,
                                  qn: selectedQuality)
    }

    // MARK: - 录制回放

    private func loadRecording(_ recording: LiveRecording) async throws {
        isLive = false
        isRecordingPlayback = true
        liveRoomID = nil
        title = recording.title
        duration = recording.duration
        currentTime = 0
        danmakuItems = []
        liveMessages = []
        replayDanmaku = []
        replayCursor = 0
        replaySeq = 0
        referer = "https://live.bilibili.com/\(recording.roomID)"
        liveDanmakuStatus = .connected

        replayDanmaku = LiveRecorder.danmaku(for: recording).sorted { $0.t < $1.t }
        if !replayDanmaku.isEmpty {
            let items = replayDanmaku.map { entry in
                DanmakuItem(time: entry.t,
                            mode: entry.mode ?? 1,
                            color: entry.color,
                            text: entry.text,
                            fontSize: entry.fontSize ?? 25)
            }
            danmakuItems = Self.assignLanes(items)
        }

        guard FileManager.default.fileExists(atPath: recording.mediaURL.path) else {
            throw BiliError.decoding("录制文件已不存在")
        }
        let asset = AVURLAsset(url: recording.mediaURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2
        player.replaceCurrentItem(with: item)
        if let length = try? await asset.load(.duration),
           length.seconds.isFinite, length.seconds > 0 {
            duration = length.seconds
        }
        player.defaultRate = Float(playbackRate)
        startPlayback()
        isPlaying = true
    }

    /// 回放时按播放进度把录制下来的弹幕重新投放到聊天面板。
    private func syncReplayDanmaku() {
        // 拖动进度条回退后，清空列表并从头补发。
        if replayCursor > 0, replayDanmaku[replayCursor - 1].t > currentTime + 0.8 {
            replayCursor = 0
            liveMessages = []
        }
        while replayCursor < replayDanmaku.count,
              replayDanmaku[replayCursor].t <= currentTime {
            let entry = replayDanmaku[replayCursor]
            let seq = replaySeq
            replaySeq += 1
            let color = NSColor(srgbRed: CGFloat((entry.color >> 16) & 0xFF) / 255,
                                green: CGFloat((entry.color >> 8) & 0xFF) / 255,
                                blue: CGFloat(entry.color & 0xFF) / 255,
                                alpha: 1)
            liveMessages.append(LiveDanmakuMessage(id: seq,
                                                   nickname: entry.nickname,
                                                   text: entry.text,
                                                   color: color))
            replayCursor += 1
        }
        if liveMessages.count > 200 {
            liveMessages.removeFirst(liveMessages.count - 200)
        }
    }

    /// 并行探测候选 HLS 节点，取最先响应的地址；探测超时则退回首选地址。
    /// ts 封装已在直播场景验证过，优先在 ts 节点中择优，没有 ts 时再退回 fmp4。
    private func pickLiveStreamURL(_ candidates: [LiveStreamCandidate]) async -> URL? {
        let preferred = candidates.filter { $0.format == "ts" }
        let pool = preferred.isEmpty ? candidates : preferred
        let urls = pool.compactMap { URL(string: $0.url) }
        guard let first = urls.first else { return nil }
        guard urls.count > 1 else { return first }

        let target = referer
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false

            func finish(_ url: URL?) {
                lock.lock()
                if finished {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()
                continuation.resume(returning: url)
            }

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 3
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config)

            for url in urls {
                Task.detached {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 3
                    request.setValue(target, forHTTPHeaderField: "Referer")
                    request.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
                    request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
                    if let (_, response) = try? await session.data(for: request),
                       let http = response as? HTTPURLResponse,
                       (200..<300).contains(http.statusCode) {
                        finish(url)
                    }
                }
            }

            Task.detached {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                finish(first)
            }
        }
    }

    // MARK: - 播放地址

    private func refreshPlayURL() async throws {
        guard let cid else { throw BiliError.decoding("缺少视频 cid") }

        // 1) DASH 才能提供 1080P 以上清晰度，以及杜比全景声 / Hi-Res 无损音轨。
        //    同时用它补全画质菜单（单文件 MP4 接口只返回 1080P 及以下）。
        //    MP4 请求与 DASH 并行，需要快速起播时不再多等一轮网络。
        async let mp4Request = fetchMP4PlayURL(cid: cid)
        let dashData = try? await requestPlayURL(cid: cid, fnval: 4048)
        if let dashData {
            updateQualities(from: dashData)
        }

        let hasHighQualityAudio = (dashData?.dash?.flac?.audio != nil)
            || !((dashData?.dash?.dolby?.audio ?? []).isEmpty)
        let wantsHighQuality = selectedQuality > 80

        // 2) 普通清晰度且没有高音质音轨时，优先单文件 MP4 快速起播：
        //    DASH 的 mcdn 主地址 AVFoundation 直接判为不支持，备用 CDN 读 moov 较慢。
        if !wantsHighQuality, !hasHighQualityAudio,
           let mp4 = await mp4Request,
           let raw = mp4.durl?.first?.url, let url = URL(string: raw) {
            audioQualityTitle = ""
            let item = AVPlayerItem(asset: AVURLAsset(url: url, options: assetOptions()))
            retainDashLoaders([])
            replaceItem(item, duration: nil)
            return
        }

        // 3) 高清晰度 / 高音质走 DASH 合成播放。
        let data: PlayURLData
        if let dashData {
            data = dashData
        } else {
            data = try await requestPlayURL(cid: cid, fnval: 4048)
            updateQualities(from: data)
        }
        try await applyPlayURL(data)
    }

    /// 单文件 MP4 地址（1080P 及以下快速起播用），失败不抛错。
    private func fetchMP4PlayURL(cid: Int) async -> PlayURLData? {
        try? await requestPlayURL(cid: cid, fnval: 1)
    }

    private func requestPlayURL(cid: Int, fnval: Int) async throws -> PlayURLData {
        if let bvid {
            return try await BiliAPI.playURL(bvid: bvid, cid: cid,
                                             quality: selectedQuality, fnval: fnval)
        }
        if let episodeID {
            return try await BiliAPI.bangumiPlayURL(epID: episodeID, cid: cid,
                                                    quality: selectedQuality, fnval: fnval)
        }
        throw BiliError.decoding("缺少视频信息")
    }

    private func updateQualities(from data: PlayURLData) {
        var seen = Set<Int>()
        let list = zip(data.accept_quality ?? [], data.accept_description ?? [])
            .compactMap { pair -> QualityOption? in
                guard seen.insert(pair.0).inserted else { return nil }
                return QualityOption(id: pair.0, title: pair.1)
            }
            .sorted { $0.id > $1.id }
        if !list.isEmpty {
            qualities = list
        }
        if let quality = data.quality, (data.accept_quality ?? []).contains(quality) {
            selectedQuality = quality
        }
    }

    private func applyPlayURL(_ data: PlayURLData) async throws {
        if let dash = data.dash {
            let headers = [
                "Referer": referer,
                "User-Agent": BiliClient.userAgent,
                "Origin": "https://www.bilibili.com"
            ]
            guard let selection = await makeDashLoader(videos: videoCandidates(dash),
                                                       audios: audioCandidates(dash),
                                                       headers: headers) else {
                throw BiliError.decoding("该视频暂不支持播放（编码不兼容）")
            }
            audioQualityTitle = Self.audioQualityName(selection.audioID)
            guard let asset = selection.loader.makeAsset() else {
                throw BiliError.decoding("该视频暂不支持播放（编码不兼容）")
            }
            let item = AVPlayerItem(asset: asset)
            retainDashLoaders([selection.loader])
            replaceItem(item, duration: dash.duration.map { Double($0) })
        } else if let durl = data.durl?.first?.url, let url = URL(string: durl) {
            audioQualityTitle = ""
            let asset = AVURLAsset(url: url, options: assetOptions())
            let item = AVPlayerItem(asset: asset)
            let length = try await asset.load(.duration)
            retainDashLoaders([])
            replaceItem(item, duration: length.seconds)
        } else {
            throw BiliError.decoding("未获取到可播放的视频流")
        }
    }

    /// 选中并在 CDN 上验证过的 DASH 组合。
    private struct DashSelection {
        let loader: DashResourceLoader
        let audioID: Int?
    }

    private static func audioQualityName(_ id: Int?) -> String {
        switch id ?? 0 {
        case 30251: return "Hi-Res 无损"
        case 30250: return "杜比全景声"
        default: return ""
        }
    }

    /// 依次尝试音视频轨的各个 CDN 地址，取第一个能读到索引的组合。
    /// 音轨不可用时退化为纯视频播放，不影响画面。
    private func makeDashLoader(videos: [DashTrack], audios: [DashTrack],
                                headers: [String: String]) async -> DashSelection? {
        var audioURL: URL?
        var audioID: Int?
        for track in audios.prefix(3) {
            guard let raw = track.url, let url = URL(string: raw) else { continue }
            if await DashResourceLoader.hasIndex(url, headers: headers) {
                audioURL = url
                audioID = track.id
                break
            }
        }

        var tried = 0
        for track in videos {
            var candidates: [String] = []
            if let url = track.url, !url.isEmpty { candidates.append(url) }
            candidates.append(contentsOf: track.backups)
            for value in candidates where tried < 4 {
                guard let url = URL(string: value) else { continue }
                tried += 1
                let loader = DashResourceLoader(videoURL: url, audioURL: audioURL, headers: headers)
                if await loader.prepare() {
                    return DashSelection(loader: loader, audioID: audioID)
                }
                loader.invalidate()
            }
        }
        return nil
    }

    /// 保活当前播放项使用的 DASH 转发器，其余立即释放。
    private func retainDashLoaders(_ loaders: [DashResourceLoader?]) {
        let next = loaders.compactMap { $0 }
        let keep = Set(next.map { ObjectIdentifier($0) })
        dashLoaders.filter { !keep.contains(ObjectIdentifier($0)) }.forEach { $0.invalidate() }
        dashLoaders = next
    }

    private func replaceItem(_ item: AVPlayerItem, duration: Double?) {
        // 缓冲 2 秒即可开播，避免等待过久。
        item.preferredForwardBufferDuration = 2
        player.replaceCurrentItem(with: item)
        if let duration, duration.isFinite, duration > 0 {
            self.duration = duration
        } else {
            // 时长异步加载：不要在时间回调里同步读 AVPlayerItem.duration，
            // 该属性会在主线程等待资源加载线程，容易触发优先级反转。
            Task { [weak self] in
                guard let self,
                      let loaded = try? await item.asset.load(.duration),
                      loaded.seconds.isFinite, loaded.seconds > 0,
                      self.player.currentItem === item else { return }
                self.duration = loaded.seconds
            }
        }
        player.defaultRate = Float(playbackRate)
        startPlayback()
        isPlaying = true
    }

    /// 预滚后再开播：让音频渲染器与视频一起就绪，避免「画面先出、声音晚几秒」。
    /// 预滚要求 AVPlayer 已进入 readyToPlay（否则会抛异常），最多等 3 秒；
    /// 预滚完成或 1.2 秒超时都会开播，不无限拖慢首帧。
    private func startPlayback() {
        playGeneration += 1
        let generation = playGeneration
        let player = self.player
        // 确保没有残留的静音/零音量状态。
        player.isMuted = false
        player.volume = 1.0

        Task { [weak self] in
            for _ in 0..<60 {
                guard let self, self.playGeneration == generation else { return }
                if player.status == .readyToPlay { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let self, self.playGeneration == generation else { return }

            guard player.status == .readyToPlay else {
                // 长时间未就绪：直接开播，交给播放器自己的缓冲/错误流程处理。
                player.play()
                return
            }

            // 此刻状态已就绪且在同一主线程内立即调用，避免状态竞态。
            player.preroll(atRate: 1) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.playGeneration == generation else { return }
                    player.play()
                }
            }

            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard self.playGeneration == generation else { return }
            player.play()
        }
    }

    /// 优先当前所选清晰度，AVC 优先（兼容性最好），同级按码率从高到低。
    private func videoCandidates(_ dash: DashData) -> [DashTrack] {
        let videos = dash.video ?? []
        func rank(_ codecid: Int?) -> Int {
            switch codecid ?? 7 {
            case 7, 0: return 0
            case 12: return 1
            case 13: return 2
            default: return 3
            }
        }
        let matched = videos.filter { ($0.id ?? 0) == selectedQuality }
        let lower = videos.filter { ($0.id ?? 0) < selectedQuality }
        let bestLowerID = lower.map { $0.id ?? 0 }.max()
        let nearest = bestLowerID.map { id in lower.filter { ($0.id ?? 0) == id } } ?? []

        func ordered(_ list: [DashTrack]) -> [DashTrack] {
            list.sorted { lhs, rhs in
                let lr = rank(lhs.codecid), rr = rank(rhs.codecid)
                if lr != rr { return lr < rr }
                if (lhs.id ?? 0) != (rhs.id ?? 0) { return (lhs.id ?? 0) > (rhs.id ?? 0) }
                return (lhs.bandwidth ?? 0) > (rhs.bandwidth ?? 0)
            }
        }

        let used = Set(matched.map { $0.id ?? 0 } + nearest.map { $0.id ?? 0 })
        let rest = videos.filter { !used.contains($0.id ?? 0) }
        return ordered(matched) + ordered(nearest) + ordered(rest)
    }

    /// 音轨优先级：Hi-Res 无损 > 杜比全景声 > 普通 AAC（按码率从高到低）。
    private func audioCandidates(_ dash: DashData) -> [DashTrack] {
        var tracks: [DashTrack] = []
        if let flac = dash.flac, let track = flac.audio, flac.display != false {
            tracks.append(track)
        }
        tracks.append(contentsOf: dash.dolby?.audio ?? [])
        let plain = (dash.audio ?? []).filter { track in
            // 杜比/Hi-Res 音轨已在 dash.audio 中时避免重复。
            guard let id = track.id else { return true }
            return id != 30250 && id != 30251
        }.sorted { ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0) }
        tracks.append(contentsOf: plain)
        return tracks
    }

    private func assetOptions() -> [String: Any] {
        ["AVURLAssetHTTPHeaderFieldsKey": [
            "Referer": referer,
            "User-Agent": BiliClient.userAgent,
            "Origin": "https://www.bilibili.com"
        ]]
    }

    /// 当前播放分 P 的下载信息。
    var downloadSource: DownloadSource? {
        guard let cid else { return nil }
        return DownloadSource(bvid: bvid, episodeID: episodeID, cid: cid, referer: referer)
    }

    /// 直播与录制回放都使用聊天面板展示弹幕。
    var showsLiveChat: Bool {
        isLive || isRecordingPlayback
    }

    // MARK: - 控制

    /// 仅在播放器真正处于播放状态时阻止屏幕息屏与系统待机。
    /// 暂停、播放结束、直播断流或加载失败后立即恢复，避免窗口还开着却无法待机。
    private func updateSleepAssertion() {
        let shouldPreventSleep = isPlaying && player.timeControlStatus == .playing
        if shouldPreventSleep {
            guard sleepActivity == nil else { return }
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: "正在播放视频/直播"
            )
        } else if let current = sleepActivity {
            ProcessInfo.processInfo.endActivity(current)
            sleepActivity = nil
        }
    }

    func togglePlay() {
        if player.rate == 0 {
            player.play()
            player.rate = Float(playbackRate)
            isPlaying = true
        } else {
            // 取消尚未执行的预滚开播，避免暂停后又被自动拉起。
            playGeneration += 1
            player.pause()
            isPlaying = false
        }
    }

    func stop() {
        playGeneration += 1
        reportHistoryBeforeStopping()
        historyTask?.cancel()
        historyTask = nil
        liveDanmaku?.disconnect()
        liveDanmaku = nil
        if isLive, LiveRecorder.shared.isRecording(owner: recordingOwner) {
            Task { await LiveRecorder.shared.stop(owner: recordingOwner) }
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        retainDashLoaders([])
        isPlaying = false
    }

    // MARK: - 历史记录上报

    /// 每 15 秒把观看进度上报给账号，视频会出现在历史记录中。
    private func startHistoryReporting() {
        guard historyTask == nil else { return }
        historyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.isPlaying, !self.isLive else { continue }
                await self.reportHistory()
            }
        }
    }

    private func reportHistory() async {
        guard episodeID == nil, let aid, let cid, currentTime > 1 else { return }
        await BiliAPI.reportVideoHistory(aid: aid, cid: cid, progress: currentTime)
    }

    /// 暂停/关闭时补报一次，避免刚看几秒就退出丢失记录。
    private func reportHistoryBeforeStopping() {
        guard episodeID == nil, let aid, let cid else { return }
        let progress = currentTime
        guard progress > 1 else { return }
        Task { await BiliAPI.reportVideoHistory(aid: aid, cid: cid, progress: progress) }
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 1000)
        currentTime = seconds
        suppressSeekUpdate = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.suppressSeekUpdate = false
            }
        }
    }

    func setRate(_ rate: Double) {
        playbackRate = rate
        player.defaultRate = Float(rate)
        if isPlaying {
            player.rate = Float(rate)
        }
    }

    func selectQuality(_ quality: Int) async {
        if isLive {
            await selectLiveQuality(quality)
            return
        }
        guard quality != selectedQuality, !isRecordingPlayback else { return }
        let resumeTime = player.currentTime().seconds
        let wasPlaying = isPlaying
        selectedQuality = quality
        do {
            try await refreshPlayURL()
            if resumeTime.isFinite, resumeTime > 0 {
                await player.seek(to: CMTime(seconds: resumeTime, preferredTimescale: 1000))
            }
            if wasPlaying {
                player.play()
                player.rate = Float(playbackRate)
                isPlaying = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playPage(index: Int) async {
        guard pages.indices.contains(index), let pageCID = pages[index].cid else { return }
        currentPageIndex = index
        cid = pageCID
        currentTime = 0
        danmakuItems = []
        do {
            try await refreshPlayURL()
            await loadDanmaku(cid: pageCID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 切换到同合集中的其他视频。
    func playSeasonEpisode(_ episode: UgcEpisode) async {
        guard let target = episode.bvid, target != bvid else { return }
        currentTime = 0
        danmakuItems = []
        isLoading = true
        do {
            try await loadVideo(identifier: target)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - 互动（点赞 / 不喜欢 / 投币 / 收藏）

    /// 转发给朋友的文本：视频标题 + 地址。
    var shareText: String {
        let link = bvid.map { "https://www.bilibili.com/video/\($0)" } ?? ""
        return link.isEmpty ? title : "【\(title)】 \(link)"
    }

    private func loadRelation() async {
        guard let bvid, BiliClient.shared.isLoggedIn else { return }
        guard let relation = try? await BiliAPI.videoRelation(bvid: bvid), self.bvid == bvid else { return }
        isLiked = relation.like ?? false
        isDisliked = relation.dislike ?? false
        isFavorited = relation.favorite ?? false
        coinsGiven = relation.coin ?? 0
    }

    func toggleLike() async {
        guard let aid else { return }
        let target = !isLiked
        guard let code = try? await BiliAPI.likeVideo(aid: aid, like: target), code == 0 else { return }
        isLiked = target
        likeCount = max(0, likeCount + (target ? 1 : -1))
    }

    func dislike() async {
        guard let aid, !isDisliked else { return }
        guard let code = try? await BiliAPI.dislikeVideo(aid: aid), code == 0 else { return }
        isDisliked = true
    }

    func addCoin() async {
        guard let aid, coinsGiven < 2 else { return }
        guard let code = try? await BiliAPI.addCoin(aid: aid), code == 0 else { return }
        coinsGiven += 1
        coinCount += 1
    }

    func toggleFavorite(userMid: Int?) async {
        guard let aid, let userMid else { return }
        if favoriteFolderID == nil {
            favoriteFolderID = (try? await BiliAPI.favoriteFolders(mid: userMid))?.list?.first?.id
        }
        guard let folderID = favoriteFolderID else { return }
        let add = !isFavorited
        guard let code = try? await BiliAPI.favoriteVideo(aid: aid, folderID: folderID, add: add),
              code == 0 else { return }
        isFavorited = add
        favoriteCount = max(0, favoriteCount + (add ? 1 : -1))
    }

    // MARK: - 弹幕与评论

    private func loadDanmaku(cid: Int) async {
        guard let items = try? await BiliClient.shared.fetchDanmaku(cid: cid) else { return }
        danmakuItems = Self.assignLanes(items)
    }

    // MARK: - 直播弹幕

    private func connectLiveDanmaku(roomID: Int) {
        liveDanmaku?.disconnect()
        liveDanmakuStatus = .connecting
        let client = LiveDanmakuClient()
        client.onDanmaku = { [weak self] item, nickname in
            self?.appendLiveDanmaku(item, nickname: nickname)
        }
        client.onState = { [weak self] state in
            self?.liveDanmakuStatus = state
        }
        client.connect(roomID: roomID)
        liveDanmaku = client
    }

    private func appendLiveDanmaku(_ incoming: DanmakuItem, nickname: String) {
        let item = DanmakuItem(time: currentTime,
                               mode: incoming.mode,
                               color: incoming.color,
                               text: incoming.text,
                               fontSize: incoming.fontSize)
        let color = NSColor(srgbRed: CGFloat((incoming.color >> 16) & 0xFF) / 255,
                            green: CGFloat((incoming.color >> 8) & 0xFF) / 255,
                            blue: CGFloat(incoming.color & 0xFF) / 255,
                            alpha: 1)
        let seq = liveDanmakuSeq
        danmakuItems.append(DanmakuLaneItem(id: seq,
                                            item: item,
                                            lane: nextLiveLane % 7,
                                            color: color))
        liveMessages.append(LiveDanmakuMessage(id: seq,
                                               nickname: nickname,
                                               text: item.text,
                                               color: color))
        liveDanmakuSeq += 1
        nextLiveLane += 1

        if let roomID = liveRoomID {
            LiveRecorder.shared.recordDanmaku(owner: recordingOwner,
                                              roomID: roomID,
                                              nickname: nickname,
                                              text: item.text,
                                              color: incoming.color,
                                              mode: incoming.mode,
                                              fontSize: incoming.fontSize)
        }

        // 只保留仍在屏幕上的弹幕，避免长时间直播累积占内存。
        danmakuItems.removeAll { currentTime - $0.item.time > 13 }
        if danmakuItems.count > 300 {
            danmakuItems.removeFirst(danmakuItems.count - 300)
        }
        if liveMessages.count > 200 {
            liveMessages.removeFirst(liveMessages.count - 200)
        }
    }

    /// 历史弹幕只有内容与昵称，没有颜色信息，统一按白色（浅色背景下会自动转深色）。
    private func loadLiveHistory(roomID: Int) async {
        guard let history = try? await BiliAPI.liveHistoryDanmaku(roomID: roomID),
              !history.isEmpty else { return }

        var messages: [LiveDanmakuMessage] = []
        messages.reserveCapacity(history.count)
        for entry in history where !entry.text.isEmpty {
            let seq = liveDanmakuSeq
            liveDanmakuSeq += 1
            messages.append(LiveDanmakuMessage(id: seq,
                                               nickname: entry.nickname,
                                               text: entry.text,
                                               color: .white))
        }
        // 历史弹幕插在实时弹幕之前；期间可能已有实时弹幕到达。
        liveMessages.insert(contentsOf: messages, at: 0)
        if liveMessages.count > 200 {
            liveMessages.removeFirst(liveMessages.count - 200)
        }
    }

    private static func assignLanes(_ items: [DanmakuItem]) -> [DanmakuLaneItem] {
        let sorted = items
            .filter { !$0.text.isEmpty }
            .sorted { $0.time < $1.time }
            .prefix(6000)
        var scrollFree = [Double](repeating: 0, count: 7)
        var topFree = [Double](repeating: 0, count: 3)
        var bottomFree = [Double](repeating: 0, count: 3)
        var result: [DanmakuLaneItem] = []
        result.reserveCapacity(sorted.count)

        for (index, item) in sorted.enumerated() {
            var lane = 0
            switch item.mode {
            case 5:
                lane = topFree.firstIndex(where: { $0 <= item.time }) ?? 0
                topFree[lane] = item.time + 4.5
            case 4:
                lane = bottomFree.firstIndex(where: { $0 <= item.time }) ?? 0
                bottomFree[lane] = item.time + 4.5
            default:
                lane = scrollFree.firstIndex(where: { $0 <= item.time }) ?? (index % scrollFree.count)
                let stay = min(12.0, 7.0 + Double(item.text.count) * 0.12)
                scrollFree[lane] = item.time + stay
            }
            let color = NSColor(srgbRed: CGFloat((item.color >> 16) & 0xFF) / 255,
                                green: CGFloat((item.color >> 8) & 0xFF) / 255,
                                blue: CGFloat(item.color & 0xFF) / 255,
                                alpha: 1)
            result.append(DanmakuLaneItem(id: index, item: item, lane: lane, color: color))
        }
        return result
    }

    private func loadComments() async {
        guard let aid else { return }
        isLoadingComments = true
        defer { isLoadingComments = false }
        guard let data = try? await BiliAPI.replies(aid: aid) else { return }
        comments = data.replies ?? []
        repliesCount = data.page?.count ?? 0
        await resolveUpLocation(comments: data.replies ?? [], pinned: data.upper?.top)
    }

    /// UP 主的 IP 属地：优先取本人（含置顶）评论的属地，没有再退回空间页的所在地。
    private func resolveUpLocation(comments: [Reply], pinned: Reply?) async {
        guard let upMid else { return }
        let candidates = [pinned].compactMap { $0 } + comments
        if let location = candidates.first(where: { $0.member?.mid == String(upMid) })?.location {
            upLocation = location
            return
        }
        if let place = await BiliAPI.spacePlace(mid: upMid) {
            upLocation = "所在地：\(place)"
        }
    }
}
