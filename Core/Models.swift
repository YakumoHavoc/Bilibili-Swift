import Foundation

// MARK: - 通用

struct BiliResponse<Data: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: Data?
}

struct Owner: Decodable, Hashable {
    let mid: Int?
    let name: String?
    let face: String?
}

struct Stat: Decodable {
    let view: Int?
    let danmaku: Int?
    let like: Int?
    let reply: Int?
    let favorite: Int?
    let coin: Int?
    let share: Int?
}

/// 当前账号对某视频的互动状态。
struct VideoRelationData: Decodable {
    let like: Bool?
    /// 已投币数量。
    let coin: Int?
    let favorite: Bool?
}

struct VideoPage: Decodable, Identifiable, Hashable {
    let cid: Int?
    let page: Int?
    let part: String?
    let duration: Int?
    var id: Int { cid ?? page ?? 0 }
}

// MARK: - 列表视频（推荐 / 热门 / 排行）

struct FeedVideoDTO: Decodable {
    let id: Int?
    let aid: Int?
    let bvid: String?
    let cid: Int?
    let pic: String?
    let title: String?
    let duration: Int?
    let pubdate: Int?
    let owner: Owner?
    let stat: Stat?
    let goto: String?
}

struct FeedListData: Decodable {
    let items: [FeedVideoDTO]?

    enum CodingKeys: String, CodingKey {
        case items = "item"
    }
}

struct PopularListData: Decodable {
    let list: [FeedVideoDTO]?
}

struct RankingListData: Decodable {
    let list: [FeedVideoDTO]?
}

struct VideoCard: Identifiable, Hashable {
    var id: String
    var bvid: String?
    var aid: Int?
    var cid: Int?
    var title: String
    var cover: String
    var duration: Int
    var upName: String
    var upFace: String
    var upMid: Int?
    var views: Int
    var danmaku: Int
    var pubdate: Int
    var badge: String?

    init(id: String, bvid: String? = nil, aid: Int? = nil, cid: Int? = nil,
         title: String, cover: String, duration: Int = 0, upName: String = "",
         upFace: String = "", upMid: Int? = nil, views: Int = 0, danmaku: Int = 0,
         pubdate: Int = 0, badge: String? = nil) {
        self.id = id
        self.bvid = bvid
        self.aid = aid
        self.cid = cid
        self.title = title
        self.cover = cover
        self.duration = duration
        self.upName = upName
        self.upFace = upFace
        self.upMid = upMid
        self.views = views
        self.danmaku = danmaku
        self.pubdate = pubdate
        self.badge = badge
    }

    init(dto: FeedVideoDTO) {
        let bvid = dto.bvid
        let aid = dto.aid ?? dto.id
        self.init(id: bvid ?? "av\(aid ?? 0)",
                  bvid: bvid,
                  aid: aid,
                  cid: dto.cid,
                  title: dto.title ?? "无标题",
                  cover: ImageURL.fix(dto.pic),
                  duration: dto.duration ?? 0,
                  upName: dto.owner?.name ?? "",
                  upFace: ImageURL.fix(dto.owner?.face),
                  upMid: dto.owner?.mid,
                  views: dto.stat?.view ?? 0,
                  danmaku: dto.stat?.danmaku ?? 0,
                  pubdate: dto.pubdate ?? 0)
    }

    var watchURL: String {
        if let bvid { return "https://www.bilibili.com/video/\(bvid)" }
        return "https://www.bilibili.com/video/av\(aid ?? 0)"
    }
}

// MARK: - 搜索

struct SearchData: Decodable {
    let result: [SearchVideoDTO]?
    let numPages: Int?
    let page: Int?
}

struct SearchVideoDTO: Decodable {
    let bvid: String?
    let aid: Int?
    let title: String?
    let author: String?
    let pic: String?
    let duration: String?
    let play: Int?
    let video_review: Int?
    let pubdate: Int?
    let mid: Int?
    let upic: String?
    let typename: String?
}

struct SearchUserData: Decodable {
    let result: [SearchUserDTO]?
    let numPages: Int?
    let page: Int?
}

struct SearchUserDTO: Decodable {
    let mid: Int?
    let uname: String?
    let usign: String?
    let upic: String?
    let fans: Int?
    let videos: Int?
    let level: Int?
    let official_verify: OfficialVerify?
}

struct OfficialVerify: Decodable {
    let type: Int?
    let desc: String?
}

// MARK: - 视频详情

struct VideoDetailData: Decodable {
    let bvid: String?
    let aid: Int?
    let cid: Int?
    let pic: String?
    let title: String?
    let desc: String?
    let duration: Int?
    let pubdate: Int?
    let owner: Owner?
    let stat: Stat?
    let pages: [VideoPage]?
    /// 视频所属的合集（UP 主自行组织），没有合集时为空。
    let ugc_season: UgcSeason?
}

// MARK: - 合集（ugc_season）

struct UgcSeason: Decodable {
    let id: Int?
    let title: String?
    let cover: String?
    let intro: String?
    let ep_count: Int?
    let stat: UgcSeasonStat?
    let sections: [UgcSection]?
}

struct UgcSeasonStat: Decodable {
    let view: Int?
}

struct UgcSection: Decodable {
    let id: Int?
    let title: String?
    let episodes: [UgcEpisode]?
}

struct UgcEpisode: Decodable, Identifiable {
    let id: Int?
    let aid: Int?
    let bvid: String?
    let cid: Int?
    let title: String?
    let arc: UgcEpisodeArc?
    let page: VideoPage?
}

struct UgcEpisodeArc: Decodable {
    let title: String?
    let pic: String?
    let duration: Int?
}

// MARK: - 播放地址

struct PlayURLData: Decodable {
    let quality: Int?
    let accept_quality: [Int]?
    let accept_description: [String]?
    let dash: DashData?
    let durl: [DurlItem]?
    let timelength: Int?
}

struct DashData: Decodable {
    let duration: Int?
    let video: [DashTrack]?
    let audio: [DashTrack]?
    /// 杜比全景声音轨（qn 30250）。
    let dolby: DashDolby?
    /// Hi-Res 无损音轨（qn 30251）。
    let flac: DashFlac?
}

struct DashDolby: Decodable {
    let type: Int?
    let audio: [DashTrack]?
}

struct DashFlac: Decodable {
    let display: Bool?
    let audio: DashTrack?
}

struct DashTrack: Decodable {
    let id: Int?
    let baseUrl: String?
    let base_url: String?
    let backupUrl: [String]?
    let backup_url: [String]?
    let bandwidth: Int?
    let codecid: Int?
    let codecs: String?
    let width: Int?
    let height: Int?
    let frameRate: String?

    var url: String? { baseUrl ?? base_url }
    var backups: [String] { backupUrl ?? backup_url ?? [] }
}

struct DurlItem: Decodable {
    let order: Int?
    let length: Int?
    let size: Int?
    let url: String?
    let backup_url: [String]?
}

// MARK: - 直播

struct LiveAreaResponse: Decodable {
    let data: [LiveParentArea]?
}

struct LiveParentArea: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let list: [LiveArea]?
}

struct LiveArea: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let parent_id: String?
    var intID: Int { Int(id) ?? 0 }
}

struct LiveRoomListData: Decodable {
    let count: Int?
    let list: [LiveRoomDTO]?
}

struct LiveRoomDTO: Decodable {
    let roomid: Int?
    let uid: Int?
    let title: String?
    let uname: String?
    let online: Int?
    let cover: String?
    let user_cover: String?
    let system_cover: String?
    let keyframe: String?
    let face: String?
    let area_name: String?
    let parent_name: String?
}

struct LiveRoom: Identifiable, Hashable {
    let id: Int
    let uid: Int?
    let title: String
    let uname: String
    let online: Int
    let cover: String
    let face: String
    let areaName: String
    let parentName: String

    init(dto: LiveRoomDTO) {
        self.id = dto.roomid ?? 0
        self.uid = dto.uid
        self.title = dto.title ?? ""
        self.uname = dto.uname ?? ""
        self.online = dto.online ?? 0
        self.cover = ImageURL.fix(dto.cover ?? dto.user_cover ?? dto.system_cover ?? dto.keyframe)
        self.face = ImageURL.fix(dto.face)
        self.areaName = dto.area_name ?? ""
        self.parentName = dto.parent_name ?? ""
    }
}

struct LivePlayInfoData: Decodable {
    let room_id: Int?
    let live_status: Int?
    let playurl_info: LivePlayURLInfo?
}

struct LiveHistoryDanmakuData: Decodable {
    let room: [LiveHistoryDanmaku]?
    let admin: [LiveHistoryDanmaku]?
}

struct LiveHistoryDanmaku: Decodable {
    let text: String
    let nickname: String
    let uid: Int?
}

struct LivePlayURLInfo: Decodable {
    let playurl: LivePlayURL?
}

struct LivePlayURL: Decodable {
    let stream: [LiveStream]?
    /// 接口给出的画质描述（杜比/4K/原画等），需与流实际支持的画质取交集。
    let g_qn_desc: [LiveQNDesc]?
}

struct LiveQNDesc: Decodable {
    let qn: Int?
    let desc: String?
}

struct LiveStream: Decodable {
    let protocol_name: String?
    let format: [LiveFormat]?
}

struct LiveFormat: Decodable {
    let format_name: String?
    let codec: [LiveCodec]?
}

struct LiveCodec: Decodable {
    let codec_name: String?
    let base_url: String?
    let url_info: [LiveURLInfo]?
    let accept_qn: [Int]?
    let current_qn: Int?
}

struct LiveURLInfo: Decodable {
    let host: String?
    let extra: String?
}

/// 直播 HLS 候选地址。
struct LiveStreamCandidate {
    let url: String
    /// "ts" 或 "fmp4"，用于优先选择兼容性更好的封装格式。
    let format: String
}

/// 直播可选清晰度。
struct LiveQuality: Identifiable, Hashable {
    let id: Int
    let title: String
}
