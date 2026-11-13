import Foundation

/// 全局表情字典：把文本里的 [表情名] 映射到图片地址。
/// 私信接口不返回 emote 字段，需要从表情面板接口补齐。
actor EmoteStore {
    static let shared = EmoteStore()

    private var infos: [String: EmoteInfo]?
    private var loading: Task<[String: EmoteInfo], Never>?

    func info(for token: String) async -> EmoteInfo? {
        if infos == nil {
            if let loading {
                infos = await loading.value
            } else {
                let task = Task { (try? await BiliAPI.emotePanel()) ?? [:] }
                loading = task
                infos = await task.value
                loading = nil
            }
        }
        return infos?[token]
    }
}
