import Foundation
import Network

/// 仅在回环地址上监听的最小 HTTP 服务，用于把 DASH 片段包装成 HLS 提供给 AVFoundation。
///
/// AVFoundation 的 HLS 引擎只接受 http(s) 的分片地址，自定义 scheme 会报
/// “custom url not redirect”，因此这里用本机 HTTP 代理转发并补上 B 站需要的请求头。
final class DashProxyServer {
    enum Route {
        /// 直接返回文本内容（播放列表）。
        case playlist(String)
        /// 转发远端文件的一段字节（分片 / 初始化段）。
        case media(url: URL, offset: Int, length: Int)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.example.BilibiliSwift.dash-proxy")
    private let headers: [String: String]
    private let routes: [String: Route]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 片段缓存的串行队列：NWConnection 回调与 URLSession 回调都可能访问。
    private let cacheQueue = DispatchQueue(label: "com.example.BilibiliSwift.dash-cache")
    /// 已预取完成、等待播放器请求的片段（路径 → 数据）。
    private var cachedSegments: [String: Data] = [:]
    private var cachedOrder: [String] = []
    private var cachedBytes = 0
    /// 正在下载的片段（路径 → 等待数据的回调）；空数组表示仅预取。
    private var pending: [String: [(Data?) -> Void]] = [:]
    /// 预取缓存上限：约十几秒的高码率画面。
    private let cacheLimit = 96 * 1024 * 1024

    private(set) var port: UInt16?

    init(routes: [String: Route], headers: [String: String]) throws {
        self.routes = routes
        self.headers = headers
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    func start() async -> UInt16? {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.port = self.listener.port?.rawValue
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        for _ in 0..<40 {
            if let port { return port }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return port
    }

    func stop() {
        listener.cancel()
        queue.async { [weak self] in
            self?.connections.values.forEach { $0.cancel() }
            self?.connections.removeAll()
        }
        cacheQueue.sync {
            cachedSegments.removeAll()
            cachedOrder.removeAll()
            cachedBytes = 0
            pending.removeAll()
        }
        session.invalidateAndCancel()
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                self.handle(head: head, on: connection)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func handle(head: String, on connection: NWConnection) {
        guard let requestLine = head.split(separator: "\r\n").first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? "/"
        guard let route = routes[path] else {
            send(status: "404 Not Found", contentType: "text/plain", body: Data(), on: connection)
            return
        }
        switch route {
        case .playlist(let text):
            send(status: "200 OK",
                 contentType: "application/vnd.apple.mpegurl",
                 body: Data(text.utf8),
                 on: connection)
        case .media(let url, let offset, let length):
            serveMedia(path: path, url: url, offset: offset, length: length, on: connection)
        }
    }

    // MARK: - 片段转发与预取

    private func serveMedia(path: String, url: URL, offset: Int, length: Int,
                            on connection: NWConnection) {
        if let data = takeCached(path) {
            // 命中预取：立即返回，同时继续向后预取，保证连续播放不断档。
            prefetch(after: path, count: 3)
            send(status: "200 OK", contentType: "video/mp4", body: data, on: connection)
            return
        }
        requestSegment(path: path, url: url, offset: offset, length: length) { [weak self] data in
            guard let self else { return }
            if let data {
                self.prefetch(after: path, count: 3)
                self.send(status: "200 OK", contentType: "video/mp4", body: data, on: connection)
            } else {
                self.send(status: "502 Bad Gateway", contentType: "text/plain", body: Data(), on: connection)
            }
        }
    }

    private func takeCached(_ path: String) -> Data? {
        cacheQueue.sync {
            guard let data = cachedSegments.removeValue(forKey: path) else { return nil }
            cachedBytes -= data.count
            if let index = cachedOrder.firstIndex(of: path) {
                cachedOrder.remove(at: index)
            }
            return data
        }
    }

    /// 请求片段数据；同一路径的重复请求合并为一次网络下载。
    private func requestSegment(path: String, url: URL, offset: Int, length: Int,
                                completion: @escaping (Data?) -> Void) {
        var immediate: Data?
        var shouldStart = false
        cacheQueue.sync {
            if let cached = cachedSegments.removeValue(forKey: path) {
                cachedBytes -= cached.count
                if let index = cachedOrder.firstIndex(of: path) {
                    cachedOrder.remove(at: index)
                }
                immediate = cached
            } else if pending[path] != nil {
                pending[path]?.append(completion)
            } else {
                pending[path] = [completion]
                shouldStart = true
            }
        }
        if let immediate {
            completion(immediate)
            return
        }
        guard shouldStart else { return }
        download(path: path, url: url, offset: offset, length: length)
    }

    /// 预取当前位置之后的若干片段，播放器真正请求时即可秒回。
    private func prefetch(after path: String, count: Int) {
        guard let parts = Self.segmentComponents(path) else { return }
        for step in 1...count {
            let nextPath = "\(parts.prefix)\(parts.index + step)\(parts.suffix)"
            guard case .media(let url, let offset, let length)? = routes[nextPath] else { continue }
            startPrefetch(path: nextPath, url: url, offset: offset, length: length)
        }
    }

    /// 解析 `/video_seg_12.mp4` 这类路径，得到前缀、序号与后缀。
    private static func segmentComponents(_ path: String) -> (prefix: String, index: Int, suffix: String)? {
        guard let range = path.range(of: "_seg_") else { return nil }
        var cursor = range.upperBound
        let digitsStart = cursor
        while cursor < path.endIndex, path[cursor].isNumber {
            cursor = path.index(after: cursor)
        }
        guard cursor > digitsStart, let index = Int(path[digitsStart..<cursor]) else { return nil }
        return (String(path[..<digitsStart]), index, String(path[cursor...]))
    }

    private func startPrefetch(path: String, url: URL, offset: Int, length: Int) {
        var shouldStart = false
        cacheQueue.sync {
            if cachedSegments[path] == nil, pending[path] == nil {
                pending[path] = []
                shouldStart = true
            }
        }
        guard shouldStart else { return }
        download(path: path, url: url, offset: offset, length: length)
    }

    private func download(path: String, url: URL, offset: Int, length: Int) {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        // 长度已知时直接要完整范围，避免依赖 Content-Range。
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30
        let task = session.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            let result = error == nil ? data : nil
            var waiters: [(Data?) -> Void] = []
            var shouldCache = false
            self.cacheQueue.sync {
                waiters = self.pending.removeValue(forKey: path) ?? []
                shouldCache = waiters.isEmpty
            }
            if shouldCache, let result, !result.isEmpty {
                self.store(result, for: path)
            }
            waiters.forEach { $0(result) }
        }
        task.resume()
    }

    private func store(_ data: Data, for path: String) {
        cacheQueue.sync {
            guard cachedSegments[path] == nil else { return }
            cachedSegments[path] = data
            cachedOrder.append(path)
            cachedBytes += data.count
            while cachedBytes > cacheLimit, let first = cachedOrder.first {
                cachedOrder.removeFirst()
                if let removed = cachedSegments.removeValue(forKey: first) {
                    cachedBytes -= removed.count
                }
            }
        }
    }

    private func send(status: String, contentType: String, body: Data, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
