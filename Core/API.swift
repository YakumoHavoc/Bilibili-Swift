import Foundation
import CryptoKit

@MainActor
enum BiliAPI {
    // MARK: - 首页 / 热门 / 排行

    /// 首页推荐流
    static func recommend(freshIndex: Int, pageSize: Int = 12) async throws -> [VideoCard] {
        let data: FeedListData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd",
            params: [
                "fresh_type": "4",
                "ps": String(pageSize),
                "fresh_idx": String(freshIndex),
                "fresh_idx_inc": "1",
                "brush": String(freshIndex),
                "web_location": "1430650"
            ],
            referer: "https://www.bilibili.com/"
        )
        return (data.items ?? []).map { VideoCard(dto: $0) }
    }

    /// 热门列表
    static func popular(page: Int) async throws -> [VideoCard] {
        let data: PopularListData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/popular",
            params: ["ps": "20", "pn": String(page)]
        )
        return (data.list ?? []).map { VideoCard(dto: $0) }
    }

    /// 排行榜
    static func ranking(rid: Int) async throws -> [VideoCard] {
        let data: RankingListData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/ranking/v2",
            params: ["rid": String(rid), "type": "all"]
        )
        return (data.list ?? []).map { VideoCard(dto: $0) }
    }

    // MARK: - 直播

    static func liveAreas() async throws -> [LiveParentArea] {
        let data: [LiveParentArea] = try await BiliClient.shared.get(
            "https://api.live.bilibili.com/room/v1/Area/getList",
            referer: "https://live.bilibili.com/"
        )
        return data
    }

    static func liveRooms(parentAreaID: Int, areaID: Int = 0, page: Int = 1) async throws -> [LiveRoom] {
        let data: LiveRoomListData = try await BiliClient.shared.get(
            "https://api.live.bilibili.com/room/v3/area/getRoomList",
            params: [
                "platform": "web",
                "parent_area_id": String(parentAreaID),
                "area_id": String(areaID),
                "sort_type": "online",
                "page": String(page),
                "page_size": "30"
            ],
            referer: "https://live.bilibili.com/"
        )
        return (data.list ?? []).map { LiveRoom(dto: $0) }
    }

    static func livePlayInfo(roomID: Int, qn: Int = 10000) async throws -> LivePlayInfoData {
        try await BiliClient.shared.get(
            "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo",
            params: [
                "room_id": String(roomID),
                "protocol": "0,1",
                "format": "0,1,2",
                "codec": "0,1",
                "qn": String(qn),
                "platform": "web"
            ],
            referer: "https://live.bilibili.com/\(roomID)"
        )
    }

    /// 直播间可选的清晰度：接口画质描述与 AVC/HLS 流实际支持画质的交集。
    static func liveQualities(from data: LivePlayInfoData) -> [LiveQuality] {
        guard let playurl = data.playurl_info?.playurl else { return [] }
        var supported = Set<Int>()
        for stream in playurl.stream ?? [] where stream.protocol_name == "http_hls" {
            for format in stream.format ?? [] {
                for codec in format.codec ?? [] where codec.codec_name == "avc" || codec.codec_name == nil {
                    if let current = codec.current_qn { supported.insert(current) }
                    for qn in codec.accept_qn ?? [] { supported.insert(qn) }
                }
            }
        }
        guard !supported.isEmpty else { return [] }

        let descs = playurl.g_qn_desc ?? []
        let list = descs.compactMap { desc -> LiveQuality? in
            guard let qn = desc.qn, supported.contains(qn) else { return nil }
            return LiveQuality(id: qn, title: desc.desc ?? liveQualityTitle(qn))
        }
        if !list.isEmpty {
            return list.sorted { $0.id > $1.id }
        }
        return supported.sorted(by: >).map { LiveQuality(id: $0, title: liveQualityTitle($0)) }
    }

    /// 服务端实际下发的清晰度（请求的画质不可用时会自动降级）。
    static func liveCurrentQuality(from data: LivePlayInfoData) -> Int? {
        for stream in data.playurl_info?.playurl?.stream ?? [] where stream.protocol_name == "http_hls" {
            for format in stream.format ?? [] {
                for codec in format.codec ?? [] where codec.codec_name == "avc" || codec.codec_name == nil {
                    if let current = codec.current_qn { return current }
                }
            }
        }
        return nil
    }

    private static func liveQualityTitle(_ qn: Int) -> String {
        switch qn {
        case 30000: return "杜比"
        case 20000: return "4K"
        case 15000: return "2K"
        case 10000: return "原画"
        case 400: return "蓝光"
        case 250: return "超清"
        case 150: return "高清"
        case 80: return "流畅"
        default: return "\(qn)"
        }
    }

    /// 直播间最近的历史弹幕，用于进入房间时先铺满弹幕列表。
    static func liveHistoryDanmaku(roomID: Int, limit: Int = 20) async throws -> [LiveHistoryDanmaku] {
        let data: LiveHistoryDanmakuData = try await BiliClient.shared.get(
            "https://api.live.bilibili.com/xlive/web-room/v1/dM/gethistory",
            params: ["roomid": String(roomID)],
            referer: "https://live.bilibili.com/\(roomID)"
        )
        let items = (data.room ?? []) + (data.admin ?? [])
        return Array(items.suffix(limit))
    }

    /// 直播流候选地址（按优先级排序）。
    ///
    /// 同一房间会返回多个 CDN 节点，且不同节点速度差异可能达十几秒，
    /// 因此这里把所有可用节点都交给上层做延迟探测，而不是只取第一个。
    /// AVFoundation 不支持 FLV，只保留 HLS（ts 优先，其次 fmp4）。
    static func liveStreamCandidates(from data: LivePlayInfoData) -> [LiveStreamCandidate] {
        guard let streams = data.playurl_info?.playurl?.stream else { return [] }

        func formatRank(_ name: String?) -> Int {
            switch name {
            case "ts": return 0
            case "fmp4": return 1
            default: return 2
            }
        }

        var result: [LiveStreamCandidate] = []
        for stream in streams where stream.protocol_name == "http_hls" {
            let formats = (stream.format ?? []).sorted {
                formatRank($0.format_name) < formatRank($1.format_name)
            }
            for format in formats {
                // 只保留 AVC：HEVC 在直播场景更容易出现兼容问题。
                guard let codec = format.codec?.first(where: { $0.codec_name == "avc" || $0.codec_name == nil }),
                      let base = codec.base_url else { continue }
                let name = format.format_name ?? "ts"
                for info in codec.url_info ?? [] {
                    let url: String
                    if base.hasPrefix("http") {
                        url = base + (info.extra ?? "")
                    } else if let host = info.host {
                        url = host + base + (info.extra ?? "")
                    } else {
                        continue
                    }
                    if !result.contains(where: { $0.url == url }) {
                        result.append(LiveStreamCandidate(url: url, format: name))
                    }
                }
            }
        }
        return result
    }

    // MARK: - 番剧 / 影视

    static func bangumi(seasonType: Int, type: Int = 1, area: String = "all",
                        year: String = "all", sort: Int = 0, page: Int = 1) async throws -> BangumiIndexData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/pgc/season/index/result",
            params: [
                "season_type": String(seasonType),
                "st": "1",
                "sort": String(sort),
                "page": String(page),
                "pagesize": "24",
                "type": String(type),
                "area": area,
                "year": year
            ],
            referer: "https://www.bilibili.com/"
        )
    }

    // MARK: - 搜索

    static func searchVideos(keyword: String, page: Int = 1, sort: String = "totalrank") async throws -> SearchData {
        let data: SearchData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/wbi/search/type",
            params: [
                "search_type": "video",
                "keyword": keyword,
                "page": String(page),
                "page_size": "20",
                "order": sort,
                "duration": "0",
                "tids": "0"
            ],
            referer: "https://search.bilibili.com/",
            signed: true
        )
        guard data.result != nil else {
            throw BiliError.api(code: -352, message: "搜索请求过于频繁，请稍后再试")
        }
        return data
    }

    static func searchUsers(keyword: String, page: Int = 1) async throws -> SearchUserData {
        let data: SearchUserData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/wbi/search/type",
            params: [
                "search_type": "bili_user",
                "keyword": keyword,
                "page": String(page),
                "page_size": "20"
            ],
            referer: "https://search.bilibili.com/",
            signed: true
        )
        guard data.result != nil else {
            throw BiliError.api(code: -352, message: "搜索请求过于频繁，请稍后再试")
        }
        return data
    }

    // MARK: - 视频详情 / 播放地址

    static func videoDetail(identifier: String) async throws -> VideoDetailData {
        let isBVID = identifier.lowercased().hasPrefix("bv")
        let params = isBVID ? ["bvid": identifier] : ["aid": identifier.lowercased().replacingOccurrences(of: "av", with: "")]
        return try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/view",
            params: params,
            referer: "https://www.bilibili.com/video/\(identifier)"
        )
    }

    /// 视频章节（分段）：UP 主在稿件里划分的时间点，来自播放器信息接口。
    static func videoChapters(aid: Int, cid: Int) async throws -> [VideoChapter] {
        let data: PlayerInfoData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/player/wbi/v2",
            params: ["aid": String(aid), "cid": String(cid)],
            referer: "https://www.bilibili.com/video/av\(aid)",
            signed: true
        )
        return (data.view_points ?? [])
            .compactMap { point in
                guard let start = point.from else { return nil }
                let title = (point.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return VideoChapter(id: Int(start), start: start, end: point.to ?? start, title: title)
            }
            .sorted { $0.start < $1.start }
    }

    static func playURL(bvid: String, cid: Int, quality: Int = 80, fnval: Int = 4048) async throws -> PlayURLData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/player/playurl",
            params: [
                "bvid": bvid,
                "cid": String(cid),
                "qn": String(quality),
                "fnval": String(fnval),
                "fnver": "0",
                "fourk": fnval == 4048 ? "1" : "0"
            ],
            referer: "https://www.bilibili.com/video/\(bvid)"
        )
    }

    // MARK: - 番剧详情 / 播放

    static func seasonInfo(epID: Int) async throws -> SeasonInfoData {
        guard let url = URL(string: "https://api.bilibili.com/pgc/view/web/season?ep_id=\(epID)") else {
            throw BiliError.invalidURL
        }
        var request = BiliClient.shared.makeRequest(url: url, referer: "https://www.bilibili.com/bangumi/play/ep\(epID)")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await BiliClient.shared.session.data(for: request)
        let wrapper = try JSONDecoder().decode(PGCResponse<SeasonInfoData>.self, from: data)
        guard let payload = wrapper.result else {
            throw BiliError.api(code: wrapper.code, message: wrapper.message ?? "")
        }
        return payload
    }

    static func bangumiPlayURL(epID: Int, cid: Int, quality: Int = 80, fnval: Int = 4048) async throws -> PlayURLData {
        guard let url = URL(string: "https://api.bilibili.com/pgc/player/web/playurl") else {
            throw BiliError.invalidURL
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "ep_id", value: String(epID)),
            URLQueryItem(name: "cid", value: String(cid)),
            URLQueryItem(name: "qn", value: String(quality)),
            URLQueryItem(name: "fnval", value: String(fnval)),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fourk", value: fnval == 4048 ? "1" : "0")
        ]
        guard let finalURL = components?.url else { throw BiliError.invalidURL }
        var request = BiliClient.shared.makeRequest(url: finalURL, referer: "https://www.bilibili.com/bangumi/play/ep\(epID)")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await BiliClient.shared.session.data(for: request)
        let wrapper = try JSONDecoder().decode(PGCResponse<PlayURLData>.self, from: data)
        guard let payload = wrapper.result else {
            throw BiliError.api(code: wrapper.code, message: wrapper.message ?? "")
        }
        return payload
    }

    // MARK: - 用户

    static func fetchNav() async -> NavData? {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else { return nil }
        let request = BiliClient.shared.makeRequest(url: url, referer: BiliClient.webReferer)
        guard let (data, _) = try? await BiliClient.shared.session.data(for: request),
              let wrapper = try? JSONDecoder().decode(BiliResponse<NavData>.self, from: data),
              let payload = wrapper.data,
              payload.isLogin == true else {
            return nil
        }
        BiliClient.shared.persistCookies()
        return payload
    }

    // MARK: - 我的

    static func history(max: Int? = nil, viewAt: Int? = nil) async throws -> HistoryData {
        var params = ["ps": "30", "business": ""]
        if let max { params["max"] = String(max) }
        if let viewAt { params["view_at"] = String(viewAt) }
        return try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/history/cursor",
            params: params,
            referer: "https://www.bilibili.com/account/history"
        )
    }

    // MARK: - 视频互动（点赞 / 投币 / 收藏）

    static func videoRelation(bvid: String) async throws -> VideoRelationData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/archive/relation",
            params: ["bvid": bvid],
            referer: "https://www.bilibili.com/video/\(bvid)/"
        )
    }

    static func likeVideo(aid: Int, like: Bool) async throws -> Int {
        try await BiliClient.shared.postForm(
            "https://api.bilibili.com/x/web-interface/archive/like",
            params: ["aid": String(aid), "like": like ? "1" : "2"],
            referer: "https://www.bilibili.com/"
        )
    }

    static func addCoin(aid: Int) async throws -> Int {
        try await BiliClient.shared.postForm(
            "https://api.bilibili.com/x/web-interface/coin/add",
            params: ["aid": String(aid), "multiply": "1", "select_like": "0"],
            referer: "https://www.bilibili.com/"
        )
    }

    static func favoriteVideo(aid: Int, folderID: Int, add: Bool) async throws -> Int {
        var params = ["rid": String(aid), "type": "2"]
        params[add ? "add_media_ids" : "del_media_ids"] = String(folderID)
        return try await BiliClient.shared.postForm(
            "https://api.bilibili.com/x/v3/fav/resource/deal",
            params: params,
            referer: "https://www.bilibili.com/"
        )
    }

    // MARK: - 推荐反馈

    /// 相关视频推荐（最多 40 条）。
    static func relatedVideos(bvid: String) async throws -> [VideoCard] {
        let items: [FeedVideoDTO] = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/archive/related",
            params: ["bvid": bvid],
            referer: "https://www.bilibili.com/video/\(bvid)/"
        )
        return items.map(VideoCard.init(dto:))
    }

    /// 推荐反馈：reasonID 1 为「内容不感兴趣」，4 为「不想看此 UP 主」。
    /// 该接口由 WBI 签名保护，故需要 signed。
    static func feedbackDislike(aid: Int, upMid: Int, reasonID: Int) async throws -> Int {
        try await BiliClient.shared.postForm(
            "https://api.bilibili.com/x/web-interface/feedback/dislike",
            params: [
                "app_id": "100",
                "platform": "5",
                "from_spmid": "",
                "spmid": "333.1007.0.0",
                "feedback_page": "1",
                "goto": "av",
                "id": String(aid),
                "mid": String(upMid),
                "track_id": "",
                "reason_id": String(reasonID)
            ],
            referer: "https://www.bilibili.com/",
            signed: true
        )
    }

    static func favoriteFolders(mid: Int) async throws -> FavoriteFolderData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v3/fav/folder/created/list-all",
            params: ["up_mid": String(mid), "web_location": "333.1387"],
            referer: "https://www.bilibili.com/account/favlist"
        )
    }

    static func favoriteList(mediaID: Int, page: Int = 1) async throws -> FavoriteListData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v3/fav/resource/list",
            params: [
                "media_id": String(mediaID),
                "pn": String(page),
                "ps": "20",
                "keyword": "",
                "order": "mtime",
                "type": "0",
                "tid": "0",
                "platform": "web"
            ],
            referer: "https://www.bilibili.com/account/favlist"
        )
    }

    static func watchLater() async throws -> ToViewData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v2/history/toview/web",
            referer: "https://www.bilibili.com/watchlater/"
        )
    }

    /// 把视频加入稍后再看，返回接口 code（0 为成功）。
    static func addWatchLater(aid: Int) async throws -> Int {
        try await BiliClient.shared.postForm(
            "https://api.bilibili.com/x/v2/history/toview/add",
            params: ["aid": String(aid)],
            referer: "https://www.bilibili.com/watchlater/"
        )
    }

    /// UP 主空间页展示的所在地（个人资料里自行填写）。
    ///
    /// 网页接口不返回该字段，只能走 App 端的空间接口（需要 appkey 签名）。
    static func spacePlace(mid: Int) async -> String? {
        let appKey = "1d8b6e7d45233436"
        let appSecret = "560c52ccd288fed045859ed18bffd973"
        var fields = [
            "vmid": String(mid),
            "appkey": appKey,
            "ts": String(Int(Date().timeIntervalSince1970)),
            "mobi_app": "android",
            "platform": "android",
            "build": "7000000"
        ]
        let query = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + appSecret).utf8))
        fields["sign"] = digest.map { String(format: "%02x", $0) }.joined()
        let body = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let data: AppSpaceData? = try? await BiliClient.shared.get(
            "https://app.bilibili.com/x/v2/space?" + body,
            referer: "https://space.bilibili.com/\(mid)"
        )
        guard let place = data?.card?.place?.trimmingCharacters(in: .whitespaces), !place.isEmpty else {
            return nil
        }
        return place
    }

    // MARK: - 动态

    static func dynamicFeed(type: String = "all", offset: String? = nil) async throws -> DynamicFeedData {
        var params = [
            "type": type,
            "timezone_offset": "-480",
            "platform": "web",
            "features": "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,decorationCard,onlyfansAssetsV2,ugcDelete,onlyfansQaCard"
        ]
        if let offset { params["offset"] = offset }
        return try await BiliClient.shared.get(
            "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all",
            params: params,
            referer: "https://t.bilibili.com/"
        )
    }

    /// 指定 UP 主的动态流（用于在动态页内直接查看某个 UP 主的动态）。
    static func spaceDynamics(mid: Int, offset: String? = nil) async throws -> DynamicFeedData {
        var params = [
            "host_mid": String(mid),
            "timezone_offset": "-480",
            "platform": "web",
            "features": "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,decorationCard,onlyfansAssetsV2,ugcDelete,onlyfansQaCard"
        ]
        if let offset { params["offset"] = offset }
        return try await BiliClient.shared.get(
            "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space",
            params: params,
            referer: "https://space.bilibili.com/\(mid)/dynamic"
        )
    }

    static func followings(mid: Int, page: Int = 1, pageSize: Int = 30) async throws -> FollowingsData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/relation/followings",
            params: [
                "vmid": String(mid),
                "pn": String(page),
                "ps": String(pageSize),
                "order": "attention"
            ],
            referer: "https://space.bilibili.com/"
        )
    }

    /// 关注的主播当前正在直播的列表（接口每页最多 20 条，需要配合 page 翻页）
    static func followingLiveFeed(page: Int = 1) async throws -> LiveFeedData {
        try await BiliClient.shared.get(
            "https://api.live.bilibili.com/relation/v1/feed/feed_list",
            params: ["page": String(page)],
            referer: "https://live.bilibili.com/"
        )
    }

    /// 全部正在直播的已关注主播：逐页拉取，直到某页为空。
    static func allFollowingLiveRooms() async throws -> [FollowingLiveRoom] {
        var result: [FollowingLiveRoom] = []
        var seen = Set<Int>()
        var page = 1
        while page <= 20 {
            let data = try await followingLiveFeed(page: page)
            let items = (data.list ?? []).map { FollowingLiveRoom(dto: $0) }
            let unique = items.filter { $0.id != 0 && seen.insert($0.id).inserted }
            result.append(contentsOf: unique)
            if items.isEmpty || unique.isEmpty { break }
            page += 1
        }
        return result
    }

    // MARK: - UP 主空间

    static func spaceInfo(mid: Int) async throws -> SpaceInfoData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/space/wbi/acc/info",
            params: ["mid": String(mid), "platform": "web"],
            referer: "https://space.bilibili.com/\(mid)",
            signed: true
        )
    }

    static func spaceVideos(mid: Int, page: Int = 1) async throws -> SpaceVideoData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/space/wbi/arc/search",
            params: [
                "mid": String(mid),
                "ps": "30",
                "pn": String(page),
                "order": "pubdate",
                "platform": "web",
                "web_location": "1550101"
            ],
            referer: "https://space.bilibili.com/\(mid)/video",
            signed: true
        )
    }

    // MARK: - 评论

    static func replies(aid: Int, page: Int = 1, sort: Int = 2) async throws -> ReplyData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v2/reply",
            params: [
                "type": "1",
                "oid": String(aid),
                "sort": String(sort),
                "ps": "20",
                "pn": String(page)
            ],
            referer: "https://www.bilibili.com/video/av\(aid)"
        )
    }

    /// 动态评论。
    ///
    /// 评论接口的 `oid` 不是动态 id：必须使用 feed 里 `basic.comment_id_str`
    /// 与 `basic.comment_type`（视频=1、图文=11、转发=17 等），否则会返回 -404。
    static func dynamicReplies(oid: String, commentType: Int,
                               refererID: String, page: Int = 1) async throws -> ReplyData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v2/reply",
            params: [
                "type": String(commentType),
                "oid": oid,
                "sort": "2",
                "ps": "20",
                "pn": String(page)
            ],
            referer: "https://t.bilibili.com/\(refererID)"
        )
    }

    /// 发表评论；回复他人时传 `root`（根评论 rpid）与 `parent`（被回复的 rpid）。
    static func addReply(aid: Int, message: String,
                         root: Int? = nil, parent: Int? = nil) async throws -> Int {
        var params: [String: String] = [
            "oid": String(aid),
            "type": "1",
            "message": message,
            "plat": "1",
            "ordering": "heat"
        ]
        if let root { params["root"] = String(root) }
        if let parent { params["parent"] = String(parent) }
        return try await BiliClient.shared.postForm(
            "https://api.bilibili.com/x/v2/reply/add",
            params: params,
            referer: "https://www.bilibili.com/video/av\(aid)"
        )
    }

    /// 点赞 / 取消点赞评论。
    static func likeReply(aid: Int, rpid: Int, liked: Bool) async throws -> Int {
        try await BiliClient.shared.postForm(
            "https://api.bilibili.com/x/v2/reply/action",
            params: [
                "oid": String(aid),
                "type": "1",
                "rpid": String(rpid),
                // 传当前状态：已赞时 action=0 取消点赞，未赞时 action=1 点赞。
                "action": liked ? "0" : "1"
            ],
            referer: "https://www.bilibili.com/video/av\(aid)"
        )
    }

    /// 某条评论下的回复（楼中楼）。
    static func replyReplies(aid: Int, root: Int, page: Int = 1) async throws -> ReplyData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v2/reply/reply",
            params: [
                "oid": String(aid),
                "type": "1",
                "root": String(root),
                "ps": "20",
                "pn": String(page)
            ],
            referer: "https://www.bilibili.com/video/av\(aid)"
        )
    }

    /// 删除自己的评论或回复。
    static func deleteReply(aid: Int, rpid: Int) async throws -> Int {
        try await BiliClient.shared.postForm(
            "https://api.bilibili.com/x/v2/reply/del",
            params: [
                "oid": String(aid),
                "type": "1",
                "rpid": String(rpid)
            ],
            referer: "https://www.bilibili.com/video/av\(aid)"
        )
    }

    // MARK: - 直播间互动

    /// 发送直播弹幕。成功与否由返回的 code 判断（0 为成功）。
    static func sendLiveDanmaku(roomID: Int, message: String) async throws -> Int {
        let csrf = BiliClient.shared.cookieValue("bili_jct") ?? ""
        return try await BiliClient.shared.postForm(
            "https://api.live.bilibili.com/msg/send",
            params: [
                "bubble": "0",
                "msg": message,
                "color": "16777215",
                "mode": "1",
                "fontsize": "25",
                "rnd": String(Int(Date().timeIntervalSince1970)),
                "roomid": String(roomID),
                "csrf_token": csrf,
                "reply_mid": "0",
                "statistics": "{\"appId\":100,\"platform\":5}"
            ],
            referer: "https://live.bilibili.com/\(roomID)"
        )
    }

    /// 当前账号的粉丝勋章墙。
    static func liveMedals() async throws -> [LiveMedal] {
        let mid = BiliClient.shared.cookieValue("DedeUserID") ?? ""
        let data: LiveMedalWallData = try await BiliClient.shared.get(
            "https://api.live.bilibili.com/xlive/web-ucenter/user/MedalWall",
            params: ["target_id": mid, "web_location": "333.1387"],
            referer: "https://live.bilibili.com/"
        )
        return (data.list ?? []).compactMap { $0.medal_info }
    }

    /// 佩戴 / 摘下粉丝勋章（`medalID` 传 0 表示摘下）。
    static func wearLiveMedal(medalID: Int) async throws -> Int {
        try await BiliClient.shared.postForm(
            "https://api.live.bilibili.com/xlive/web-room/v1/fansMedal/wear",
            params: ["medal_id": String(medalID)],
            referer: "https://live.bilibili.com/"
        )
    }

    // MARK: - 观看历史

    /// 上报视频观看进度，写入账号的历史记录（登录后生效）。
    static func reportVideoHistory(aid: Int, cid: Int, progress: Double) async {
        _ = try? await BiliClient.shared.postForm(
            "https://api.bilibili.com/x/v2/history/report",
            params: [
                "aid": String(aid),
                "cid": String(cid),
                "progress": String(max(0, Int(progress))),
                "platform": "android"
            ],
            referer: "https://www.bilibili.com/video/av\(aid)"
        )
    }

    /// 上报进入直播间，写入直播观看记录（登录后生效）。
    static func reportLiveEntry(roomID: Int) async {
        _ = try? await BiliClient.shared.postForm(
            "https://api.live.bilibili.com/room/v1/Room/room_entry_action",
            params: [
                "room_id": String(roomID),
                "platform": "web"
            ],
            referer: "https://live.bilibili.com/\(roomID)"
        )
    }
}
