import SwiftUI

/// 消息中心：左侧分类导航，右侧最近消息列表与详情。
struct MessagesView: View {
    @EnvironmentObject private var app: AppState

    private enum Category: String, CaseIterable, Identifiable {
        case sessions
        case replies
        case mentions
        case likes
        case system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sessions: return "我的消息"
            case .replies: return "回复我的"
            case .mentions: return "@ 我的"
            case .likes: return "收到的赞"
            case .system: return "系统通知"
            }
        }

        var listTitle: String {
            self == .sessions ? "最近消息" : "最新消息"
        }
    }

    @State private var category: Category = .sessions
    @State private var sessions: [MsgSession] = []
    @State private var cards: [Int: MsgUserCard] = [:]
    @State private var replies: [MsgFeedReplyItem] = []
    @State private var mentions: [MsgFeedAtItem] = []
    @State private var likes: [MsgFeedLikeItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var selectedSession: MsgSession?
    @State private var selectedFeedID: Int?
    @State private var conversation: [MsgConversationMessage] = []
    @State private var isLoadingConversation = false

    var body: some View {
        Group {
            if !BiliClient.shared.isLoggedIn {
                LoginPromptView(title: "登录后即可查看消息") {
                    app.showLogin = true
                }
                .background(Palette.bg)
            } else {
                HStack(spacing: 0) {
                    categoryRail
                    Divider().overlay(Palette.line)
                    VStack(spacing: 0) {
                        header
                        Divider().overlay(Palette.line)
                        content
                    }
                }
                .background(Palette.bg)
            }
        }
        .task(id: category) {
            selectedSession = nil
            selectedFeedID = nil
            conversation = []
            await load()
        }
    }

    // MARK: - 左侧分类

    private var categoryRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .font(.ui(14, weight: .semibold))
                    .foregroundStyle(Palette.text1)
                Text("消息中心")
                    .font(.ui(15, weight: .semibold))
                    .foregroundStyle(Palette.text1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 14)

            ForEach(Category.allCases) { item in
                categoryRow(item)
            }

            Spacer()

            Button {
                app.showToast("消息设置暂未开放")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.ui(12))
                    Text("消息设置")
                        .font(.ui(13))
                    Spacer()
                }
                .foregroundStyle(Palette.text2)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
        }
        .frame(width: 210)
        .background(Palette.navBackground)
    }

    private func categoryRow(_ item: Category) -> some View {
        let selected = category == item
        return Button {
            category = item
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(selected ? Palette.pink : Palette.text3.opacity(0.45))
                    .frame(width: 5, height: 5)
                Text(item.title)
                    .font(.ui(13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.pink : Palette.text2)
                Spacer()
                if item == .sessions, totalUnread > 0 {
                    Text(totalUnread > 99 ? "99+" : "\(totalUnread)")
                        .font(.ui(10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Palette.pink)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Text(category.title)
                .font(.ui(16, weight: .semibold))
                .foregroundStyle(Palette.text1)
            Spacer()
            PlainIconButton(systemName: "arrow.clockwise", action: {
                Task { await load() }
            }, help: "刷新")
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
    }

    // MARK: - 内容区

    private var content: some View {
        HStack(spacing: 0) {
            listColumn
            Divider().overlay(Palette.line)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text(category.listTitle)
                    .font(.ui(12))
                    .foregroundStyle(Palette.text2)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 40)

            if isLoading {
                LoadingStateView()
                    .frame(maxHeight: .infinity)
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await load() }
                }
                .frame(maxHeight: .infinity)
            } else if rows.isEmpty {
                emptyHint
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row)
                        }
                    }
                }
            }
        }
        .frame(width: 340)
    }

    @ViewBuilder
    private var detailPane: some View {
        if category == .sessions, let session = selectedSession {
            conversationPane(session)
        } else if let feed = selectedFeed {
            feedDetail(feed)
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.ui(46, weight: .light))
                .foregroundStyle(Palette.text3.opacity(0.7))
            Text("快找小伙伴聊天吧")
                .font(.ui(13))
                .foregroundStyle(Palette.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.ui(30, weight: .light))
                .foregroundStyle(Palette.text3.opacity(0.7))
            Text(category == .system ? "暂无系统通知" : "暂无消息")
                .font(.ui(13))
                .foregroundStyle(Palette.text3)
        }
    }

    // MARK: - 列表行

    private enum Row: Identifiable {
        case session(MsgSession)
        case reply(MsgFeedReplyItem)
        case mention(MsgFeedAtItem)
        case like(MsgFeedLikeItem)

        var id: String {
            switch self {
            case .session(let item): return "s\(item.ident)"
            case .reply(let item): return "r\(item.ident)"
            case .mention(let item): return "a\(item.ident)"
            case .like(let item): return "l\(item.ident)"
            }
        }
    }

    private var rows: [Row] {
        switch category {
        case .sessions: return sessions.map(Row.session)
        case .replies: return replies.map(Row.reply)
        case .mentions: return mentions.map(Row.mention)
        case .likes: return likes.map(Row.like)
        case .system: return []
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .session(let session):
            messageRow(avatar: sessionAvatar(session),
                       name: sessionName(session),
                       snippet: Self.plainText(session.last_msg?.content, type: session.last_msg?.msg_type),
                       badge: session.unread_count ?? 0,
                       time: session.last_msg?.timestamp ?? session.session_ts ?? 0,
                       selected: selectedSession?.ident == session.ident) {
                selectedSession = session
                conversation = []
                Task { await loadConversation(session) }
            }
        case .reply(let item):
            messageRow(avatar: ImageURL.thumb(item.user?.avatar, width: 80, height: 80),
                       name: item.user?.nickname ?? "",
                       snippet: feedSnippet(item.item),
                       badge: item.is_multi == 1 ? (item.counts ?? 0) : 0,
                       time: item.reply_time ?? 0,
                       selected: selectedFeedID == item.ident) {
                selectedFeedID = item.ident
            }
        case .mention(let item):
            messageRow(avatar: ImageURL.thumb(item.user?.avatar, width: 80, height: 80),
                       name: item.user?.nickname ?? "",
                       snippet: feedSnippet(item.item),
                       badge: 0,
                       time: item.at_time ?? 0,
                       selected: selectedFeedID == item.ident) {
                selectedFeedID = item.ident
            }
        case .like(let item):
            messageRow(avatar: ImageURL.thumb(item.users?.first?.avatar, width: 80, height: 80),
                       name: likeNames(item),
                       snippet: likeSnippet(item),
                       badge: item.counts ?? 0,
                       time: item.like_time ?? 0,
                       selected: selectedFeedID == item.ident) {
                selectedFeedID = item.ident
            }
        }
    }

    private func messageRow(avatar: String,
                            name: String,
                            snippet: String,
                            badge: Int,
                            time: Int,
                            selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AvatarView(url: avatar, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.ui(13, weight: .medium))
                            .foregroundStyle(Palette.text1)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.relativeDate(time))
                            .font(.ui(10))
                            .foregroundStyle(Palette.text3)
                    }
                    HStack(spacing: 6) {
                        CommentMessageText(message: snippet,
                                           emotes: [:],
                                           fontSize: 11,
                                           color: Palette.text2,
                                           onSaveEmote: { token, url in
                                               saveEmote(token: token, url: url)
                                           })
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.ui(10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Palette.pink)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(selected ? Palette.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 详情

    @ViewBuilder
    private func conversationPane(_ session: MsgSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AvatarView(url: sessionAvatar(session), size: 26)
                Text(sessionName(session))
                    .font(.ui(14, weight: .semibold))
                    .foregroundStyle(Palette.text1)
                Spacer()
            }
            .padding(.horizontal, 22)
            .frame(height: 54)

            Divider().overlay(Palette.line)

            if isLoadingConversation {
                LoadingStateView().frame(maxHeight: .infinity)
            } else if conversation.isEmpty {
                emptyDetail
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(conversation.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }, id: \.ident) { message in
                            bubble(message)
                                .id(message.ident)
                        }
                    }
                    .padding(20)
                }
                // 打开会话时直接定位到最新消息，而不是停在最早的记录。
                .defaultScrollAnchor(.bottom)
            }
        }
    }

    private func bubble(_ message: MsgConversationMessage) -> some View {
        let mine = message.sender_uid == app.user?.mid
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if let video = Self.sharedVideo(message.content, type: message.msg_type) {
                    videoCard(video, time: message.timestamp ?? 0)
                } else {
                    CommentMessageText(message: Self.plainText(message.content, type: message.msg_type),
                                       emotes: [:],
                                       fontSize: 12,
                                       color: mine ? .white : Palette.text1,
                                       onOpenUserName: { name in
                                           app.openUser(named: name)
                                       },
                                       onSaveEmote: { token, url in
                                           saveEmote(token: token, url: url)
                                       })
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(mine ? Palette.pink : Palette.bgRegular)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(Fmt.relativeDate(message.timestamp ?? 0))
                    .font(.ui(9))
                    .foregroundStyle(Palette.text3)
            }
            if !mine { Spacer(minLength: 40) }
        }
    }

    /// 右键另存私信里的表情。
    private func saveEmote(token: String, url: String) {
        Task {
            switch await ImageSaver.save(urlString: url, suggestedName: ImageSaver.emoteFileName(token)) {
            case .saved:
                app.showToast("表情已保存")
            case .failed:
                app.showToast("表情保存失败")
            case .cancelled:
                break
            }
        }
    }

    /// 私信里的视频分享卡片：封面 + 标题 + 作者/时长，点击直接播放。
    private func videoCard(_ video: SharedVideo, time: Int) -> some View {
        Button {
            guard let identifier = video.identifier else {
                app.showToast("无法播放该视频")
                return
            }
            PlayerWindowController.shared.open(identifier: identifier, title: video.title, app: app)
        } label: {
            HStack(spacing: 10) {
                Color.clear
                    .frame(width: 112, height: 63)
                    .overlay {
                        RemoteImage(url: ImageURL.thumb(video.cover, width: 224, height: 126))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .bottomTrailing) {
                        if video.duration > 0 {
                            Text(Fmt.duration(video.duration))
                                .font(.ui(9, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.black.opacity(0.65))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .padding(4)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title.isEmpty ? "视频" : video.title)
                        .font(.ui(12, weight: .medium))
                        .foregroundStyle(Palette.text1)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        if !video.author.isEmpty {
                            Text(video.author)
                                .lineLimit(1)
                        }
                        Text(Fmt.relativeDate(time))
                    }
                    .font(.ui(10))
                    .foregroundStyle(Palette.text3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(width: 300, alignment: .leading)
            .background(Palette.bgRegular)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("播放视频")
    }

    @ViewBuilder
    private func feedDetail(_ feed: FeedDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AvatarView(url: feed.avatar, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.name)
                        .font(.ui(13, weight: .semibold))
                        .foregroundStyle(Palette.text1)
                    Text("\(feed.business) · \(Fmt.relativeDate(feed.time))")
                        .font(.ui(10))
                        .foregroundStyle(Palette.text3)
                }
                Spacer()
            }

            CommentMessageText(message: feed.content,
                               emotes: [:],
                               fontSize: 13,
                               paidScale: 4,
                               onOpenUserName: { name in
                                   app.openUser(named: name)
                               },
                               onSaveEmote: { token, url in
                                   saveEmote(token: token, url: url)
                               })

            if !feed.title.isEmpty {
                CommentMessageText(message: feed.title,
                                   emotes: [:],
                                   fontSize: 12,
                                   color: Palette.text2,
                                   paidScale: 4,
                                   onSaveEmote: { token, url in
                                       saveEmote(token: token, url: url)
                                   })
                    .lineLimit(2)
            }

            if feed.bvid != nil {
                Button {
                    PlayerWindowController.shared.open(identifier: feed.bvid!, title: feed.title, app: app)
                } label: {
                    Text("查看原视频")
                        .font(.ui(12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Palette.pink)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct FeedDetail {
        let avatar: String
        let name: String
        let business: String
        let content: String
        let title: String
        let time: Int
        let bvid: String?
    }

    private var selectedFeed: FeedDetail? {
        guard let id = selectedFeedID else { return nil }
        switch category {
        case .replies:
            guard let item = replies.first(where: { $0.ident == id }) else { return nil }
            return FeedDetail(avatar: ImageURL.thumb(item.user?.avatar, width: 80, height: 80),
                              name: item.user?.nickname ?? "",
                              business: item.item?.business ?? "消息",
                              content: feedContent(item.item),
                              title: item.item?.title ?? "",
                              time: item.reply_time ?? 0,
                              bvid: Self.bvid(from: item.item?.uri))
        case .mentions:
            guard let item = mentions.first(where: { $0.ident == id }) else { return nil }
            return FeedDetail(avatar: ImageURL.thumb(item.user?.avatar, width: 80, height: 80),
                              name: item.user?.nickname ?? "",
                              business: item.item?.business ?? "消息",
                              content: feedContent(item.item),
                              title: item.item?.title ?? "",
                              time: item.at_time ?? 0,
                              bvid: Self.bvid(from: item.item?.uri))
        case .likes:
            guard let item = likes.first(where: { $0.ident == id }) else { return nil }
            return FeedDetail(avatar: ImageURL.thumb(item.users?.first?.avatar, width: 80, height: 80),
                              name: likeNames(item),
                              business: item.item?.business ?? "点赞",
                              content: "赞了我的\(item.item?.type == "reply" ? "评论" : "内容")",
                              title: item.item?.title ?? "",
                              time: item.like_time ?? 0,
                              bvid: Self.bvid(from: item.item?.uri))
        default:
            return nil
        }
    }

    // MARK: - 数据

    private var totalUnread: Int {
        sessions.reduce(0) { $0 + ($1.unread_count ?? 0) }
    }

    private func load() async {
        guard BiliClient.shared.isLoggedIn else { return }
        isLoading = true
        errorMessage = nil
        do {
            switch category {
            case .sessions:
                let list = try await BiliAPI.messageSessions()
                sessions = list
                let uids = list.compactMap { $0.talker_id }.filter { $0 > 0 }
                if !uids.isEmpty {
                    let fetched = try await BiliAPI.userCards(uids: uids)
                    var map: [Int: MsgUserCard] = [:]
                    for card in fetched {
                        if let mid = card.mid { map[mid] = card }
                    }
                    cards = map
                }
            case .replies:
                replies = try await BiliAPI.replyMessages()
            case .mentions:
                mentions = try await BiliAPI.atMessages()
            case .likes:
                likes = try await BiliAPI.likeMessages()
            case .system:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadConversation(_ session: MsgSession) async {
        guard let uid = session.talker_id else { return }
        isLoadingConversation = true
        conversation = (try? await BiliAPI.conversationMessages(talkerID: uid)) ?? []
        isLoadingConversation = false
    }

    private func sessionAvatar(_ session: MsgSession) -> String {
        guard let mid = session.talker_id, let face = cards[mid]?.face else { return "" }
        return ImageURL.thumb(face, width: 80, height: 80)
    }

    private func sessionName(_ session: MsgSession) -> String {
        if let name = cards[session.talker_id ?? 0]?.name, !name.isEmpty { return name }
        if let group = session.group_name, !group.isEmpty { return group }
        return session.talker_id.map { "用户 \($0)" } ?? "未知会话"
    }

    private func likeNames(_ item: MsgFeedLikeItem) -> String {
        let names = (item.users ?? []).compactMap { $0.nickname }
        guard let first = names.first else { return "有人" }
        if let counts = item.counts, counts > names.count {
            return "\(first) 等共计 \(counts) 人"
        }
        return names.count > 1 ? "\(first) 等 \(names.count) 人" : first
    }

    /// 「收到的赞」列表摘要：说明点赞动作，并附上被赞内容。
    private func likeSnippet(_ item: MsgFeedLikeItem) -> String {
        let action = "赞了我的\(item.item?.type == "reply" ? "评论" : "内容")"
        guard let title = item.item?.title, !title.isEmpty else { return action }
        return "\(action)：\(title)"
    }

    private func feedSnippet(_ item: MsgFeedTarget?) -> String {
        guard let item else { return "" }
        let prefix = item.business.map { "[\($0)]" } ?? ""
        return prefix + (item.title ?? "")
    }

    private func feedContent(_ item: MsgFeedTarget?) -> String {
        guard let item else { return "" }
        for text in [item.target_reply_content, item.root_reply_content, item.source_content] {
            if let text, !text.isEmpty { return text }
        }
        return item.title ?? ""
    }

    private static func bvid(from uri: String?) -> String? {
        guard let uri,
              let range = uri.range(of: "BV[0-9A-Za-z]+", options: .regularExpression) else { return nil }
        return String(uri[range])
    }

    /// 私信中的视频分享消息（类型 7 为视频分享、11 为视频卡片）。
    private struct SharedVideo {
        let title: String
        let cover: String
        let author: String
        let duration: Int
        let identifier: String?
    }

    private static func sharedVideo(_ content: String?, type: Int?) -> SharedVideo? {
        guard type == 7 || type == 11,
              let content,
              let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = json["title"] as? String ?? ""
        let cover = json["thumb"] as? String ?? json["cover"] as? String ?? ""
        let author = json["author"] as? String ?? ""
        let duration = json["times"] as? Int ?? 0

        let raw = json["id"] ?? json["rid"]
        var identifier: String?
        if let aid = raw as? Int {
            identifier = "av\(aid)"
        } else if let text = raw as? String, !text.isEmpty {
            identifier = text.hasPrefix("BV") ? text : Int(text).map { "av\($0)" }
        }
        guard !cover.isEmpty || identifier != nil else { return nil }
        return SharedVideo(title: title, cover: cover, author: author, duration: duration, identifier: identifier)
    }

    /// 私信内容多为 JSON 字符串，按消息类型提取可读文本。
    private static func plainText(_ content: String?, type: Int?) -> String {
        guard let content, !content.isEmpty else { return "[消息]" }
        switch type {
        case 2: return "[图片]"
        case 3: return "[表情]"
        default: break
        }
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return content
        }
        if let text = json["content"] as? String, !text.isEmpty { return text }
        if let title = json["title"] as? String, !title.isEmpty { return "[视频] \(title)" }
        if json["cover"] != nil { return "[视频]" }
        return "[消息]"
    }
}
