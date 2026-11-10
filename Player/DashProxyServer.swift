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
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

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
            fetch(url: url, offset: offset, length: length, on: connection)
        }
    }

    private func fetch(url: URL, offset: Int, length: Int, on connection: NWConnection) {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        // 长度已知时直接要完整范围，避免依赖 Content-Range。
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            guard let data, error == nil, !data.isEmpty else {
                self.send(status: "502 Bad Gateway", contentType: "text/plain", body: Data(), on: connection)
                return
            }
            self.send(status: "200 OK", contentType: "video/mp4", body: data, on: connection)
        }
        task.resume()
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
