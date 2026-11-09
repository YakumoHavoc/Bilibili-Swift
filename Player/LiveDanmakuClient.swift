import Foundation
import Compression

struct LiveDanmuInfo: Decodable {
    let token: String?
    let host_list: [LiveDanmuHost]?
}

struct LiveDanmuHost: Decodable {
    let host: String?
    let wss_port: Int?
}

enum LiveDanmakuStatus: Equatable {
    case connecting
    case connected
    case failed(String)
    case closed
}

/// 直播弹幕 WebSocket 客户端：连接房间、心跳保活、解析 DANMU_MSG。
@MainActor
final class LiveDanmakuClient {
    var onDanmaku: ((DanmakuItem, String) -> Void)?
    var onState: ((LiveDanmakuStatus) -> Void)?

    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var roomID = 0
    private var stopped = false
    private var lastFailure = ""
    private var receivedFrames = 0

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    deinit {
        runTask?.cancel()
        heartbeatTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    func connect(roomID: Int) {
        stop()
        self.roomID = roomID
        stopped = false
        emit(.connecting)
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    func disconnect() {
        stop()
        // 断开后该客户端不再复用，释放 URLSession 的连接池与接收缓冲。
        session.invalidateAndCancel()
    }

    private func stop() {
        stopped = true
        runTask?.cancel()
        runTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func emit(_ status: LiveDanmakuStatus) {
        onState?(status)
    }

    // MARK: - 连接流程

    /// 获取 token → 逐个 host 尝试 → 认证成功后进入接收循环；断开后自动重连。
    private func run() async {
        var failedAttempts = 0
        Self.log("开始连接弹幕 room=\(roomID)")

        while !Task.isCancelled && !stopped {
            do {
                let info = try await fetchDanmuInfo()
                guard let token = info.token else {
                    throw BiliError.decoding("弹幕服务器列表为空")
                }
                failedAttempts = 0
                Self.log("获取 token 成功 hosts=\((info.host_list ?? []).count)")

                var connected = false
                let hosts = (info.host_list ?? []).filter { ($0.host ?? "").isEmpty == false }
                // 官方接口偶发只给少数节点，全部失败后再补一个公共接入点。
                var fallback = hosts
                fallback.append(LiveDanmuHost(host: "broadcastlv.chat.bilibili.com", wss_port: 443))

                for host in fallback {
                    if Task.isCancelled || stopped { return }
                    if await connectOnce(host: host, token: token) {
                        connected = true
                        break
                    }
                }

                if !connected {
                    failedAttempts += 1
                    Self.log("全部节点连接失败 count=\(fallback.count)")
                    emit(.failed("无法连接弹幕服务器（已尝试 \(fallback.count) 个节点：\(lastFailure)）"))
                } else if !Task.isCancelled && !stopped {
                    // 连接被服务端断开，准备重连。
                    Self.log("连接被服务端断开，准备重连")
                    emit(.connecting)
                }
            } catch {
                failedAttempts += 1
                Self.log("获取弹幕服务器失败：\(error.localizedDescription)")
                emit(.failed("获取弹幕服务器失败：\(error.localizedDescription)"))
            }

            if Task.isCancelled || stopped { return }
            // 首次失败快些重试，后续放慢，避免频繁请求触发风控。
            let delay = failedAttempts >= 2 ? 5.0 : 1.5
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// 优先用 WBI 签名请求；签名接口偶发失败时退回无签名请求。
    private func fetchDanmuInfo() async throws -> LiveDanmuInfo {
        do {
            return try await BiliClient.shared.get(
                "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo",
                params: ["id": String(roomID), "type": "0"],
                referer: "https://live.bilibili.com/\(roomID)",
                signed: true
            )
        } catch {
            Self.log("签名请求失败：\(error.localizedDescription)，改用无签名请求")
            return try await BiliClient.shared.get(
                "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo",
                params: ["id": String(roomID), "type": "0"],
                referer: "https://live.bilibili.com/\(roomID)"
            )
        }
    }

    /// 返回 true 表示曾成功连上（随后断线由外层重连）；false 表示该节点不可用。
    private func connectOnce(host: LiveDanmuHost, token: String) async -> Bool {
        guard let name = host.host, !name.isEmpty,
              let url = URL(string: "wss://\(name):\(host.wss_port ?? 443)/sub") else {
            lastFailure = "节点地址无效"
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(BiliClient.webReferer, forHTTPHeaderField: "Referer")
        request.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")

        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()

        do {
            try await sendAuth(on: task, token: token)
        } catch {
            lastFailure = "发送认证包失败（\(name)）"
            Self.log("发送认证包失败 host=\(name) \(error.localizedDescription)")
            close(task)
            return false
        }

        guard await Self.waitAuthorization(task), !Task.isCancelled, !stopped else {
            lastFailure = "认证超时或失败（\(name)）"
            Self.log("认证失败 host=\(name)")
            close(task)
            return false
        }

        lastFailure = ""
        Self.log("已连接 host=\(name)")
        emit(.connected)
        startHeartbeat()

        await receiveLoop(task)

        Self.log("接收循环结束 host=\(name)")
        heartbeatTask?.cancel()
        heartbeatTask = nil
        close(task)
        return true
    }

    private func close(_ task: URLSessionWebSocketTask) {
        task.cancel(with: .goingAway, reason: nil)
        if socket === task {
            socket = nil
        }
    }

    /// 等待认证回包（op=8，code=0）。
    ///
    /// 全程只有一个读取者，且运行在非主线程：早前实现用「2 秒超时 + 重新 receive」
    /// 会遗留读消息的任务（可能吞掉认证包），而且认证回包的处理依赖主线程；
    /// 播放器初始化把主线程占满时就会误判为连接失败。
    nonisolated private static func waitAuthorization(_ socket: URLSessionWebSocketTask) async -> Bool {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var watchdog: Task<Void, Never>?

            func finish(_ value: Bool) {
                lock.lock()
                if finished {
                    lock.unlock()
                    return
                }
                finished = true
                let pending = watchdog
                lock.unlock()
                // 认证已结束时必须取消看门狗，否则它会在 10 秒后把正常连接掐断。
                pending?.cancel()
                continuation.resume(returning: value)
            }

            watchdog = Task.detached {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                socket.cancel(with: .goingAway, reason: nil)
                finish(false)
            }

            Task.detached {
                while true {
                    guard let message = try? await socket.receive(),
                          let data = payload(of: message) else {
                        finish(false)
                        return
                    }
                    if let authorized = authResult(in: data) {
                        finish(authorized)
                        return
                    }
                }
            }
        }
    }

    /// 从一帧数据里找出认证回包，返回是否认证成功；没有认证帧则返回 nil。
    nonisolated private static func authResult(in data: Data) -> Bool? {
        for frame in frames(in: data) where frame.op == 8 {
            guard let object = try? JSONSerialization.jsonObject(with: frame.body) as? [String: Any] else {
                return true
            }
            if let code = object["code"] as? Int {
                return code == 0
            }
            return true
        }
        return nil
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let socket = self.socket else { return }
                try? await socket.send(.data(self.packetData(op: 2, body: Data())))
            }
        }
    }

    /// 收包循环放在非主线程，主线程忙于播放器渲染时也不会堆积/丢帧。
    nonisolated private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            guard let message = try? await task.receive(),
                  let data = Self.payload(of: message) else { return }
            await handle(data)
        }
    }

    // MARK: - 协议

    private func sendAuth(on task: URLSessionWebSocketTask, token: String) async throws {
        // 认证包必须带上当前登录账号的 uid：实测 uid=0（匿名）会被服务端直接断开，
        // 且不会有 op=8 回包，表现为「认证失败」。buvid 一并带上，规避风控。
        let uid = Int(BiliClient.shared.cookieValue("DedeUserID") ?? "") ?? 0
        let buvid = BiliClient.shared.cookieValue("buvid3") ?? ""
        let payload: [String: Any] = [
            "uid": uid,
            "roomid": roomID,
            "protover": 2,
            "buvid": buvid,
            "platform": "web",
            "type": 2,
            "key": token
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await task.send(.data(packetData(op: 7, body: body)))
    }

    private func handle(_ data: Data) {
        for frame in Self.frames(in: data) where frame.op == 5 {
            receivedFrames += 1
            if receivedFrames == 1 || receivedFrames % 100 == 0 {
                Self.log("已收到弹幕帧 \(receivedFrames) 个")
            }
            if frame.version == 2 {
                // 压缩帧解压后仍是完整的帧序列，需要递归解析。
                if let inflated = Self.inflate(frame.body) {
                    handle(inflated)
                }
            } else if frame.version == 0 || frame.version == 1 {
                parse(frame.body)
            }
        }
    }

    private func parse(_ body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let cmd = object["cmd"] as? String, cmd.hasPrefix("DANMU_MSG"),
              let info = object["info"] as? [Any], info.count > 1,
              let text = info[1] as? String, !text.isEmpty else { return }

        var mode = 1
        var color = 0xFFFFFF
        if let meta = info[0] as? [Any], meta.count > 3 {
            if let value = meta[1] as? Int { mode = value }
            if let value = meta[3] as? Int, (0...0xFFFFFF).contains(value) { color = value }
        }

        // info[2] 是发送者信息数组，索引 1 为昵称。
        var nickname = ""
        if let user = info[2] as? [Any], user.count > 1, let name = user[1] as? String {
            nickname = name
        }

        onDanmaku?(DanmakuItem(time: 0, mode: mode, color: color, text: text, fontSize: 25), nickname)
    }

    private func packetData(op: UInt32, body: Data) -> Data {
        var data = Data()
        data.append(contentsOf: Self.uint32Bytes(UInt32(body.count + 16)))
        data.append(contentsOf: Self.uint16Bytes(16))
        data.append(contentsOf: Self.uint16Bytes(1))
        data.append(contentsOf: Self.uint32Bytes(op))
        data.append(contentsOf: Self.uint32Bytes(1))
        data.append(body)
        return data
    }

    // MARK: - 帧解析工具

    private struct Frame {
        let op: UInt32
        let version: UInt16
        let body: Data
    }

    nonisolated private static func frames(in data: Data) -> [Frame] {
        var result: [Frame] = []
        var offset = 0
        while offset + 16 <= data.count {
            let total = Int(readUInt32(data, offset))
            guard total >= 16, offset + total <= data.count else { break }
            let headerLength = Int(readUInt16(data, offset + 4))
            guard headerLength >= 16, headerLength <= total else { break }
            let version = readUInt16(data, offset + 6)
            let op = readUInt32(data, offset + 8)
            let body = data.subdata(in: (offset + headerLength)..<(offset + total))
            result.append(Frame(op: op, version: version, body: body))
            offset += total
        }
        return result
    }

    nonisolated private static func payload(of message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            return text.data(using: .utf8)
        @unknown default:
            return nil
        }
    }

    nonisolated private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    nonisolated private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    nonisolated private static func uint16Bytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    nonisolated private static func uint32Bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// B 站帧体是 zlib 容器；Apple 的 COMPRESSION_ZLIB 只接受裸 DEFLATE，
    /// 需要先剥掉 2 字节头（若含字典标识则再跳过 4 字节）。
    nonisolated private static func inflate(_ data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        var bytes = Array(data)
        let flg = bytes[1]
        var offset = 2
        if flg & 0x20 != 0 { offset += 4 }
        bytes.removeFirst(offset)

        func decode(capacity: Int) -> Data? {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }
            let size = bytes.withUnsafeBufferPointer { buffer -> Int in
                guard let source = buffer.baseAddress else { return 0 }
                return compression_decode_buffer(destination, capacity, source, buffer.count,
                                                 nil, COMPRESSION_ZLIB)
            }
            guard size > 0 else { return nil }
            return Data(bytes: destination, count: size)
        }

        // 热门房间的压缩包可能很大，按 20 倍预留；仍失败时再放大一倍重试。
        return decode(capacity: max(bytes.count * 20, 1 << 18))
            ?? decode(capacity: max(bytes.count * 40, 1 << 19))
    }

    /// 最小化诊断日志：只记录连接状态与计数，不记录弹幕正文。
    nonisolated static func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/BilibiliDanmaku.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
