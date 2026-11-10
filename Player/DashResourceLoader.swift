import AVFoundation
import Foundation

/// 把 B 站单文件 DASH 片段包装成 HLS 播放列表交给 AVFoundation 播放。
///
/// 直接播放 `.m4s` 有两个问题：AVFoundation 依后缀判断容器类型（报 -11828），
/// 且分片 MP4 没有样本表，时长与索引只能靠顺序扫描整个文件（1080P+ 动辄 2 GB），
/// 实际表现为长时间卡住或提示编码不兼容。
/// 这里利用文件头部的 `sidx` 盒（B 站 DASH 均带此索引）按分片生成 HLS 列表，
/// 再由本机 HTTP 代理转发分片并补上 B 站需要的 Referer，起播与拖动都正常。
final class DashResourceLoader {
    private struct Segment {
        let offset: Int
        let length: Int
        let duration: Double
    }

    private struct TrackIndex {
        let segments: [Segment]
        /// 初始化段（ftyp + moov）的字节长度。
        let initLength: Int
        let totalLength: Int
    }

    private struct Track {
        let url: URL
        let index: TrackIndex
    }

    private let videoURL: URL
    private let audioURL: URL?
    private let headers: [String: String]
    private let lock = NSLock()

    private var server: DashProxyServer?
    private var playlistURL: URL?

    init(videoURL: URL, audioURL: URL?, headers: [String: String]) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.headers = headers
    }

    deinit {
        server?.stop()
    }

    func invalidate() {
        lock.lock()
        let server = self.server
        self.server = nil
        playlistURL = nil
        lock.unlock()
        server?.stop()
    }

    /// 只校验地址可访问且带索引，用于挑选音轨时不启动代理。
    static func hasIndex(_ url: URL, headers: [String: String]) async -> Bool {
        await fetchIndex(url, headers: headers) != nil
    }

    /// 读取两条轨道的文件头，解析 `sidx` 索引并启动本机代理。
    /// 返回 false 表示资源不可访问或缺少索引，调用方应尝试下一个地址。
    func prepare() async -> Bool {
        guard let videoIndex = await Self.fetchIndex(videoURL, headers: headers) else {
            return false
        }
        var audioTrack: Track?
        if let audioURL, let audioIndex = await Self.fetchIndex(audioURL, headers: headers) {
            audioTrack = Track(url: audioURL, index: audioIndex)
        }
        let videoTrack = Track(url: videoURL, index: videoIndex)

        var routes: [String: DashProxyServer.Route] = [
            "/master.m3u8": .playlist(Self.masterPlaylist(video: videoTrack, hasAudio: audioTrack != nil)),
            "/video.m3u8": .playlist(Self.mediaPlaylist(for: videoTrack, name: "video"))
        ]
        Self.addMediaRoutes(track: videoTrack, name: "video", into: &routes)
        if let audioTrack {
            routes["/audio.m3u8"] = .playlist(Self.mediaPlaylist(for: audioTrack, name: "audio"))
            Self.addMediaRoutes(track: audioTrack, name: "audio", into: &routes)
        }

        let server: DashProxyServer
        do {
            server = try DashProxyServer(routes: routes, headers: headers)
        } catch {
            return false
        }
        guard let port = await server.start() else {
            server.stop()
            return false
        }
        lock.lock()
        self.server = server
        playlistURL = URL(string: "http://127.0.0.1:\(port)/master.m3u8")
        lock.unlock()
        return true
    }

    /// 需要与播放项同生命周期持有。
    func makeAsset() -> AVURLAsset? {
        guard let playlistURL else { return nil }
        return AVURLAsset(url: playlistURL, options: [:])
    }

    private static func addMediaRoutes(track: Track, name: String,
                                       into routes: inout [String: DashProxyServer.Route]) {
        routes["/\(name)_init.mp4"] = .media(url: track.url, offset: 0, length: track.index.initLength)
        for (index, segment) in track.index.segments.enumerated() {
            routes["/\(name)_seg_\(index).mp4"] = .media(url: track.url,
                                                         offset: segment.offset,
                                                         length: segment.length)
        }
    }

    // MARK: - 索引解析

    /// 读取文件头部（含 ftyp/moov/sidx），得到分段索引。
    private static func fetchIndex(_ url: URL, headers: [String: String]) async -> TrackIndex? {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 206 || http.statusCode == 200 else { return nil }
        let total = totalLength(from: http) ?? data.count
        return trackIndex(in: data, totalLength: total)
    }

    private static func totalLength(from response: HTTPURLResponse) -> Int? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last,
           let value = Int(total) {
            return value
        }
        return response.expectedContentLength > 0 ? Int(response.expectedContentLength) : nil
    }

    private struct Box {
        let type: String
        let offset: Int
        let size: Int
    }

    private static func boxes(in data: Data, from start: Int, to end: Int) -> [Box] {
        var result: [Box] = []
        var offset = start
        while offset + 8 <= end {
            let size = Int(data.readUInt32(at: offset))
            let type = data.readASCII(at: offset + 4, length: 4)
            if size < 8 || offset + size > end { break }
            result.append(Box(type: type, offset: offset, size: size))
            offset += size
        }
        return result
    }

    private static func trackIndex(in data: Data, totalLength: Int) -> TrackIndex? {
        let top = boxes(in: data, from: 0, to: data.count)
        guard let sidx = top.first(where: { $0.type == "sidx" }) else { return nil }
        let end = sidx.offset + sidx.size
        let version = data[data.index(data.startIndex, offsetBy: sidx.offset + 8)]
        let timescale = Int(data.readUInt32(at: sidx.offset + 16))
        var cursor = sidx.offset + 28 + (version == 0 ? 0 : 8)
        guard timescale > 0, cursor + 4 <= end else { return nil }
        let count = Int(data.readUInt16(at: cursor + 2))
        cursor += 4
        guard count > 0, cursor + count * 12 <= end else { return nil }

        var offset = end
        var segments: [Segment] = []
        segments.reserveCapacity(count)
        for _ in 0..<count {
            let length = Int(data.readUInt32(at: cursor))
            let duration = Int(data.readUInt32(at: cursor + 4))
            cursor += 12
            guard length > 0 else { continue }
            segments.append(Segment(offset: offset,
                                    length: length,
                                    duration: Double(duration) / Double(timescale)))
            offset += length
        }
        guard !segments.isEmpty else { return nil }
        // 初始化段只取 ftyp + moov：sidx 索引不属于初始化信息。
        let initLength = top.first(where: { $0.type == "moov" }).map { $0.offset + $0.size } ?? sidx.offset
        return TrackIndex(segments: segments, initLength: initLength, totalLength: totalLength)
    }

    private static func masterPlaylist(video: Track, hasAudio: Bool) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        if hasAudio {
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"")
        }
        let duration = video.index.segments.reduce(0) { $0 + $1.duration }
        let bitrate = duration > 0 ? Int(Double(video.index.totalLength) * 8 / duration) : 2_500_000
        let audio = hasAudio ? ",AUDIO=\"aud\"" : ""
        lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(max(bitrate, 1_000_000))\(audio)")
        lines.append("video.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func mediaPlaylist(for track: Track, name: String) -> String {
        let maxDuration = track.index.segments.map { $0.duration }.max() ?? 1
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-TARGETDURATION:\(max(1, Int(maxDuration.rounded(.up))))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-MAP:URI=\"\(name)_init.mp4\""
        ]
        for (index, segment) in track.index.segments.enumerated() {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("\(name)_seg_\(index).mp4")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - 二进制读取

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return self[index(startIndex, offsetBy: offset)..<index(startIndex, offsetBy: offset + 2)]
            .reduce(0) { ($0 << 8) | UInt16($1) }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return self[index(startIndex, offsetBy: offset)..<index(startIndex, offsetBy: offset + 4)]
            .reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func readASCII(at offset: Int, length: Int) -> String {
        guard offset >= 0, offset + length <= count else { return "" }
        let start = index(startIndex, offsetBy: offset)
        let slice = self[start..<index(start, offsetBy: length)]
        return String(decoding: slice, as: UTF8.self)
    }
}
