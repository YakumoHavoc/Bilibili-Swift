import Foundation

// MARK: - 番剧 / 影视

struct BangumiIndexData: Decodable {
    let has_next: Int?
    let list: [BangumiItemDTO]?
}

struct BangumiItemDTO: Decodable {
    let season_id: Int?
    let media_id: Int?
    let title: String?
    let cover: String?
    let index_show: String?
    let score: String?
    let badge: String?
    let link: String?
    let subTitle: String?
    let season_type_name: String?
    let first_ep: BangumiEpisode?
}

struct BangumiEpisode: Decodable {
    let ep_id: Int?
    let cover: String?
}

struct BangumiItem: Identifiable, Hashable {
    var id: Int
    var title: String
    var cover: String
    var indexShow: String
    var score: String
    var badge: String
    var subtitle: String
    var link: String
    var epID: Int?

    init(dto: BangumiItemDTO) {
        self.id = dto.season_id ?? dto.media_id ?? 0
        self.title = dto.title ?? "无标题"
        self.cover = ImageURL.fix(dto.cover)
        self.indexShow = dto.index_show ?? ""
        self.score = dto.score ?? ""
        self.badge = dto.badge ?? ""
        self.subtitle = dto.subTitle ?? ""
        self.link = dto.link ?? ""
        self.epID = dto.first_ep?.ep_id
    }
}

// MARK: - 用户

struct UserProfile: Equatable {
    var mid: Int
    var name: String
    var face: String
    var level: Int
    var isVIP: Bool
    var signature: String
}

struct NavData: Decodable {
    let isLogin: Bool?
    let uname: String?
    let face: String?
    let mid: Int?
    let vipStatus: Int?
    let signature: String?
    let level_info: LevelInfo?
}

struct LevelInfo: Decodable {
    let current_level: Int?
}

// MARK: - 收藏 / 历史 / 稍后再看

struct FavoriteFolderData: Decodable {
    let count: Int?
    let list: [FavoriteFolder]?
}

struct FavoriteFolder: Decodable, Identifiable, Hashable {
    let id: Int
    let fid: Int?
    let mid: Int?
    /// 收藏夹列表接口返回 title，部分接口返回 name，两者兼容。
    let title: String?
    let name: String?
    let media_count: Int?

    var displayName: String {
        title ?? name ?? "未命名收藏夹"
    }
}

struct FavoriteListData: Decodable {
    let info: FavoriteFolder?
    let medias: [FavoriteMedia]?
    let has_more: Bool?
}

struct FavoriteMedia: Decodable, Identifiable {
    let id: Int
    let bvid: String?
    let title: String?
    let cover: String?
    let duration: Int?
    let upper: Owner?
    let cnt_info: FavoriteCount?
    let attr: Int?
}

struct FavoriteCount: Decodable {
    let play: Int?
    let danmaku: Int?
    let collect: Int?
}

struct FavoriteCard: Identifiable, Hashable {
    var id: Int
    var bvid: String?
    var title: String
    var cover: String
    var duration: Int
    var upName: String
    var upFace: String
    var upMid: Int?
    var views: Int
    var invalid: Bool
}

struct HistoryData: Decodable {
    let cursor: HistoryCursor?
    let list: [HistoryItem]?
}

struct HistoryCursor: Decodable {
    let max: Int?
    let view_at: Int?
    let business: String?
}

struct HistoryItem: Decodable {
    let title: String?
    let long_title: String?
    let cover: String?
    let author_name: String?
    let author_mid: Int?
    let view_at: Int?
    let progress: Int?
    let duration: Int?
    let videos: Int?
    let badge: String?
    let history: HistoryRecord?
}

struct HistoryRecord: Decodable {
    let oid: Int?
    let bvid: String?
    let cid: Int?
    let page: Int?
    let part: String?
}

struct HistoryCard: Identifiable, Hashable {
    var id: String
    var bvid: String?
    var cid: Int?
    var title: String
    var cover: String
    var upName: String
    var upMid: Int?
    var progress: Int
    var duration: Int
    var viewAt: Int
}

struct ToViewData: Decodable {
    let count: Int?
    let list: [ToViewItem]?
}

struct ToViewItem: Decodable {
    let aid: Int?
    let bvid: String?
    let cid: Int?
    let title: String?
    let pic: String?
    let duration: Int?
    let owner: Owner?
    let stat: Stat?
    let progress: Int?
    let add_at: Int?
}

// MARK: - 动态

struct DynamicFeedData: Decodable {
    let items: [DynamicItem]?
    let has_more: Bool?
    let offset: String?
}

struct DynamicItem: Decodable, Identifiable {
    let id_str: String
    let type: String?
    let basic: DynamicBasic?
    let modules: DynamicModules?
    let orig: DynamicOrig?
    var id: String { id_str }
}

/// 动态的评论定位信息：评论接口必须用这里的 type/oid，而不是动态 id。
struct DynamicBasic: Decodable {
    let comment_type: Int?
    let comment_id_str: String?

    private enum CodingKeys: String, CodingKey {
        case comment_type, comment_id_str
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decodeIfPresent(Int.self, forKey: .comment_type) {
            comment_type = value
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .comment_type) {
            comment_type = Int(text)
        } else {
            comment_type = nil
        }

        if let text = try? container.decodeIfPresent(String.self, forKey: .comment_id_str) {
            comment_id_str = text
        } else if let value = try? container.decodeIfPresent(Int.self, forKey: .comment_id_str) {
            comment_id_str = String(value)
        } else {
            comment_id_str = nil
        }
    }
}

/// 转发动态的原动态（只解析一层，避免结构体递归）。
struct DynamicOrig: Decodable {
    let id_str: String?
    let type: String?
    let basic: DynamicBasic?
    let modules: DynamicModules?
}

struct DynamicModules: Decodable {
    let module_author: DynamicAuthor?
    let module_dynamic: DynamicContent?
    let module_stat: DynamicStat?
}

struct DynamicAuthor: Decodable {
    let mid: Int?
    let name: String?
    let face: String?
    let pub_time: String?
    let pub_ts: Int?

    private enum CodingKeys: String, CodingKey {
        case mid, name, face, pub_time, pub_ts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = (try? container.decodeIfPresent(Int.self, forKey: .mid))
            ?? Int((try? container.decodeIfPresent(String.self, forKey: .mid)) ?? "")
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        face = try? container.decodeIfPresent(String.self, forKey: .face)
        pub_time = try? container.decodeIfPresent(String.self, forKey: .pub_time)
        if let value = try? container.decodeIfPresent(Int.self, forKey: .pub_ts) {
            pub_ts = value
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .pub_ts) {
            pub_ts = Int(text)
        } else {
            pub_ts = nil
        }
    }
}

struct DynamicContent: Decodable {
    let desc: DynamicDesc?
    let major: DynamicMajor?
}

struct DynamicDesc: Decodable {
    let text: String?
}

struct DynamicMajor: Decodable {
    let type: String?
    let archive: DynamicArchive?
    let draw: DynamicDraw?
    let article: DynamicArticle?
    let pgc: DynamicPGC?
    let opus: DynamicOpus?
    let live_rcmd: DynamicLiveRcmd?
}

/// 直播推荐动态：`content` 是一段 JSON 字符串，需要二次解析。
struct DynamicLiveRcmd: Decodable {
    let content: String?
    let reserve_type: Int?

    var playInfo: LiveRcmdPlayInfo? {
        guard let content, let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LiveRcmdContent.self, from: data).live_play_info
    }
}

struct LiveRcmdContent: Decodable {
    let live_play_info: LiveRcmdPlayInfo?
}

struct LiveRcmdPlayInfo: Decodable {
    let room_id: Int?
    let uid: Int?
    let live_status: Int?
    let title: String?
    let cover: String?
    let online: Int?
    let area_name: String?
    let parent_area_name: String?
    let uname: String?
    let face: String?

    var asLiveRoom: LiveRoom {
        LiveRoom(dto: LiveRoomDTO(roomid: room_id, uid: uid, title: title, uname: uname,
                                  online: online, cover: cover, user_cover: nil,
                                  system_cover: nil, keyframe: nil, face: face,
                                  area_name: area_name, parent_name: parent_area_name))
    }
}

/// 新版图文动态（OPUS），正文与图片都在这里。
struct DynamicOpus: Decodable {
    let title: String?
    let summary: DynamicDesc?
    let pics: [DynamicOpusPic]?
    let jump_url: String?
}

struct DynamicOpusPic: Decodable {
    let url: String?
    let width: Int?
    let height: Int?
}

struct DynamicArticle: Decodable {
    let title: String?
    let desc: String?
    let covers: [String]?
    let jump_url: String?
    let label: String?
}

struct DynamicPGC: Decodable {
    let title: String?
    let cover: String?
    let jump_url: String?
    let epid: String?
}

struct DynamicArchive: Decodable {
    let bvid: String?
    let title: String?
    let cover: String?
    let desc: String?
    let stat: DynamicArchiveStat?
}

struct DynamicArchiveStat: Decodable {
    let play: String?
    let danmaku: String?
}

struct DynamicDraw: Decodable {
    let items: [DynamicDrawItem]?
}

struct DynamicDrawItem: Decodable {
    let src: String?
    let width: Int?
    let height: Int?
}

struct DynamicStat: Decodable {
    let comment: DynamicCount?
    let like: DynamicCount?
    let forward: DynamicCount?
}

struct DynamicCount: Decodable {
    let count: Int?
}

// MARK: - 关注列表 / 关注直播

struct FollowingsData: Decodable {
    let list: [FollowingDTO]?
    let total: Int?
}

struct FollowingDTO: Decodable {
    let mid: Int?
    let uname: String?
    let face: String?
}

struct FollowingUser: Identifiable, Hashable {
    var id: Int
    var name: String
    var face: String
}

struct LiveFeedData: Decodable {
    let list: [LiveFeedDTO]?
}

struct LiveFeedDTO: Decodable {
    let roomid: Int?
    let uid: Int?
    let uname: String?
    let face: String?
    let title: String?
    let cover: String?
    let online: Int?
}

struct FollowingLiveRoom: Identifiable, Hashable {
    var id: Int
    var uid: Int?
    var name: String
    var title: String
    var face: String
    var cover: String
    var online: Int

    init(dto: LiveFeedDTO) {
        self.id = dto.roomid ?? 0
        self.uid = dto.uid
        self.name = dto.uname ?? ""
        self.title = dto.title ?? ""
        self.face = ImageURL.fix(dto.face)
        self.cover = ImageURL.fix(dto.cover ?? dto.face)
        self.online = dto.online ?? 0
    }

    var asLiveRoom: LiveRoom {
        LiveRoom(dto: LiveRoomDTO(roomid: id, uid: uid, title: title, uname: name,
                                  online: online, cover: cover, user_cover: nil,
                                  system_cover: nil, keyframe: nil, face: face,
                                  area_name: nil, parent_name: nil))
    }
}

// MARK: - UP 主空间

struct SpaceInfoData: Decodable {
    let mid: Int?
    let name: String?
    let face: String?
    let sign: String?
    let fans: Int?
    let attention: Int?
    let level: Int?
}

/// App 端空间接口的返回，只用到个人资料里的所在地。
struct AppSpaceData: Decodable {
    let card: AppSpaceCard?
}

struct AppSpaceCard: Decodable {
    let place: String?
}

struct SpaceVideoData: Decodable {
    let list: SpaceVideoList?
    let page: SpacePage?
}

struct SpaceVideoList: Decodable {
    let vlist: [SpaceVideoDTO]?
}

struct SpacePage: Decodable {
    let pn: Int?
    let ps: Int?
    let count: Int?
}

struct SpaceVideoDTO: Decodable {
    let aid: Int?
    let bvid: String?
    let title: String?
    let pic: String?
    let length: String?
    let play: Int?
    let comment: Int?
    let created: Int?
    let author: String?
    let mid: Int?
}

// MARK: - 评论

struct ReplyData: Decodable {
    let page: ReplyPage?
    let replies: [Reply]?
    /// UP 主置顶评论的包装（`top` 才是评论本身），用于取 UP 主的 IP 属地。
    let upper: ReplyUpper?
}

struct ReplyUpper: Decodable {
    let top: Reply?
}

struct ReplyPage: Decodable {
    let count: Int?
    let acount: Int?
}

struct Reply: Decodable, Identifiable {
    let rpid: Int?
    let member: ReplyMember?
    let content: ReplyContent?
    var like: Int?
    let ctime: Int?
    let reply_control: ReplyControl?
    /// 楼中楼的根评论 rpid（顶层评论为 0）。
    let root: Int?
    /// 被回复评论的 rpid。
    let parent: Int?
    /// 该评论下的回复数量。
    var rcount: Int?
    /// 当前账号的点赞状态：1 已点赞、0 未点赞。
    var action: Int?
    var id: Int { rpid ?? 0 }

    var isLiked: Bool { (action ?? 0) == 1 }

    /// 评论者的 IP 属地（登录后由接口返回，形如「IP属地：浙江」）。
    var location: String? {
        guard let location = reply_control?.location, !location.isEmpty else { return nil }
        return location
    }
}

struct ReplyControl: Decodable {
    let location: String?
}

struct ReplyMember: Decodable {
    /// 接口返回的是字符串。
    let mid: String?
    let uname: String?
    let avatar: String?
}

struct ReplyContent: Decodable {
    let message: String?
    /// 表情字典：key 为占位符（如 "[doge]"），value 为图片地址。
    let emote: [String: ReplyEmote]?
    /// 评论里附带的图片。
    let pictures: [ReplyPicture]?
}

struct ReplyEmote: Decodable {
    let url: String?
}

struct ReplyPicture: Decodable {
    let img_src: String?
}

// MARK: - 番剧详情 / PGC

struct PGCResponse<Result: Decodable>: Decodable {
    let code: Int
    let message: String?
    let result: Result?
}

struct SeasonInfoData: Decodable {
    let season_id: Int?
    let season_title: String?
    let title: String?
    let cover: String?
    let evaluate: String?
    let episodes: [EpisodeDTO]?
    let stat: PGCStat?
}

struct EpisodeDTO: Decodable {
    let ep_id: Int?
    let id: Int?
    let aid: Int?
    let bvid: String?
    let cid: Int?
    let title: String?
    let long_title: String?
    let cover: String?
    let duration: Int?
    let pub_time: Int?
}

struct PGCStat: Decodable {
    let views: Int?
    let danmakus: Int?
    let likes: Int?
}

// MARK: - 弹幕

struct DanmakuItem {
    let time: Double
    let mode: Int
    let color: Int
    let text: String
    let fontSize: Double
}

// MARK: - 消息中心

struct MsgFeedUser: Decodable {
    let mid: Int?
    let nickname: String?
    let avatar: String?
}

/// 消息关联的原始内容（视频、动态、评论等）。
struct MsgFeedTarget: Decodable {
    let title: String?
    let business: String?
    let type: String?
    let uri: String?
    let image: String?
    let subject_id: Int?
    let source_content: String?
    let root_reply_content: String?
    let target_reply_content: String?
    let like_state: Int?
}

struct MsgFeedReplyItem: Decodable {
    let id: Int?
    let user: MsgFeedUser?
    let item: MsgFeedTarget?
    let counts: Int?
    let is_multi: Int?
    let reply_time: Int?
    var ident: Int { id ?? 0 }
}

struct MsgFeedAtItem: Decodable {
    let id: Int?
    let user: MsgFeedUser?
    let item: MsgFeedTarget?
    let at_time: Int?
    var ident: Int { id ?? 0 }
}

struct MsgFeedLikeItem: Decodable {
    let id: Int?
    let users: [MsgFeedUser]?
    let item: MsgFeedTarget?
    /// 该条点赞消息聚合的人数（接口返回整数）。
    let counts: Int?
    let like_time: Int?
    var ident: Int { id ?? 0 }
}

struct MsgFeedList<T: Decodable>: Decodable {
    let items: [T]?
}

struct MsgLikeFeedData: Decodable {
    let total: MsgFeedList<MsgFeedLikeItem>?
}

/// 私信会话。
struct MsgSession: Decodable {
    let talker_id: Int?
    let unread_count: Int?
    let session_ts: Int?
    let group_name: String?
    let last_msg: MsgLastMessage?
    var ident: Int { talker_id ?? 0 }
}

struct MsgLastMessage: Decodable {
    let content: String?
    let msg_type: Int?
    let timestamp: Int?
}

struct MsgUserCard: Decodable {
    let mid: Int?
    let name: String?
    let face: String?
}

struct MsgSessionData: Decodable {
    let session_list: [MsgSession]?
}

struct MsgConversationMessage: Decodable {
    let msg_key: Int?
    let msg_type: Int?
    let content: String?
    let timestamp: Int?
    let sender_uid: Int?
    var ident: Int { msg_key ?? 0 }
}

struct MsgMessagesData: Decodable {
    let messages: [MsgConversationMessage]?
}

