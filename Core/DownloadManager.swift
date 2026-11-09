import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import AppKit

/// 下载来源：普通视频或番剧剧集。cid 为当前正在播放的分 P。
struct DownloadSource {
    let bvid: String?
    let episodeID: Int?
    let cid: Int
    let referer: String
}

struct DownloadTaskItem: Identifiable {
    enum State: Equatable {
        case preparing
        case downloading
        case merging
        case finished
        case failed
    }

    let id: UUID
    let title: String
    let qualityTitle: String
    let createdAt: Date
    var danmakuCount: Int = 0
    var state: State = .preparing
    var progress: Double = 0
    var fileURL: URL?
    var error: String?

    var isActive: Bool {
        state == .preparing || state == .downloading || state == .merging
    }

    var stateText: String {
        switch state {
        case .preparing: return "准备中"
        case .downloading: return "下载中 \(Int(progress * 100))%"
        case .merging: return "合并中"
        case .finished: return "已完成"
        case .failed: return "失败"
        }
    }
}

/// 每个视频/直播单独一个文件夹，meta.json 记录来源与文件列表，
/// 重新启动或迁移到其他设备后可直接扫描恢复下载页内容。
struct DownloadMeta: Codable {
    let id: UUID
    let title: String
    let qualityTitle: String
    let createdAt: Date
    let duration: Double
    let danmakuCount: Int
    let mediaFile: String
    let danmakuFile: String
    let bvid: String?
    let cid: Int?
    let episodeID: Int?
}

/// 视频下载：拉取 DASH 音视频流（与 bilibili-helper 一致），下载后合成为 MP4，并保存弹幕。
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var tasks: [DownloadTaskItem] = []

    /// 正在执行的任务句柄，用于取消当前网络请求。
    private var downloads: [UUID: FileDownloader] = [:]
    private var runners: [UUID: Task<Void, Never>] = [:]
    private var cancelled: Set<UUID> = []

    private init() {
        loadDownloads()
    }

    // MARK: - 对外接口

    func start(source: DownloadSource, quality: Int, qualityTitle: String, title: String) {
        let item = DownloadTaskItem(id: UUID(), title: title, qualityTitle: qualityTitle, createdAt: Date())
        tasks.insert(item, at: 0)
        let runner = Task { [weak self] in
            guard let self else { return }
            await self.run(id: item.id, source: source, quality: quality,
                           qualityTitle: qualityTitle, title: title)
        }
        runners[item.id] = runner
    }

    func cancel(_ id: UUID) {
        cancelled.insert(id)
        runners[id]?.cancel()
        runners[id] = nil
        downloads[id]?.cancel()
        downloads[id] = nil
        tasks.removeAll { $0.id == id }
    }

    func clearFinished() {
        tasks.removeAll { $0.state == .finished || $0.state == .failed }
    }

    /// 重新扫描下载目录下的文件夹，恢复下载页内容（启动或打开下载页时调用）。
    /// 每个视频/直播一个文件夹，因此把整个目录复制到其他设备也能直接识别。
    func loadDownloads() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: downloadDirectory,
                                                        includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var merged: [UUID: DownloadTaskItem] = [:]
        for folder in entries {
            let isDirectory = (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
                  let meta = try? JSONDecoder().decode(DownloadMeta.self, from: data) else { continue }
            let media = folder.appendingPathComponent(meta.mediaFile)
            guard fm.fileExists(atPath: media.path) else { continue }
            var item = DownloadTaskItem(id: meta.id, title: meta.title,
                                        qualityTitle: meta.qualityTitle, createdAt: meta.createdAt)
            item.state = .finished
            item.progress = 1
            item.fileURL = media
            item.danmakuCount = meta.danmakuCount
            merged[item.id] = item
        }
        for item in tasks where item.isActive {
            merged[item.id] = item
        }
        tasks = merged.values.sorted { $0.createdAt > $1.createdAt }
    }

    func reveal(_ id: UUID) {
        guard let url = tasks.first(where: { $0.id == id })?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealDownloadsFolder() {
        NSWorkspace.shared.open(downloadDirectory)
    }

    // MARK: - 流程

    private func run(id: UUID, source: DownloadSource, quality: Int,
                     qualityTitle: String, title: String) async {
        defer {
            downloads[id] = nil
            runners[id] = nil
            cancelled.remove(id)
        }
        do {
            let data = try await requestPlayURL(source: source, quality: quality)
            if let dash = data.dash, !(dash.video ?? []).isEmpty {
                do {
                    try await downloadDASH(id: id, dash: dash, quality: quality,
                                           title: title, qualityTitle: qualityTitle, source: source)
                    return
                } catch {
                    // 用户取消或 DASH 合成失败时不再走单文件兜底。
                    guard !cancelled.contains(id), !Task.isCancelled else { return }
                }
            }
            let muxed = try await requestPlayURL(source: source, quality: quality, fnval: 1)
            guard let urlString = muxed.durl?.first?.url else {
                throw BiliError.decoding("未获取到可下载的视频流")
            }
            try await downloadMuxed(id: id, urlString: urlString, title: title,
                                    qualityTitle: qualityTitle, source: source)
        } catch {
            guard !cancelled.contains(id), !Task.isCancelled,
                  var item = tasks.first(where: { $0.id == id }) else { return }
            item.state = .failed
            item.error = error.localizedDescription
            update(item)
        }
    }

    private func requestPlayURL(source: DownloadSource, quality: Int, fnval: Int = 4048) async throws -> PlayURLData {
        if let bvid = source.bvid {
            return try await BiliAPI.playURL(bvid: bvid, cid: source.cid, quality: quality, fnval: fnval)
        }
        if let episodeID = source.episodeID {
            return try await BiliAPI.bangumiPlayURL(epID: episodeID, cid: source.cid, quality: quality, fnval: fnval)
        }
        throw BiliError.decoding("缺少视频信息")
    }

    /// DASH：分别下载视频轨与音频轨，再合成 MP4。
    private func downloadDASH(id: UUID, dash: DashData, quality: Int, title: String,
                              qualityTitle: String, source: DownloadSource) async throws {
        guard let videoTrack = pickVideoTrack(dash, quality: quality) else {
            throw BiliError.decoding("未找到可下载的视频轨")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bili-download-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        updateState(id, .downloading, progress: 0)

        let videoFile = tempDir.appendingPathComponent("video.mp4")
        let audioTrack = pickAudioTrack(dash)
        let hasAudio = audioTrack != nil

        try await downloadTrack(videoTrack, to: videoFile, id: id,
                                range: 0...(hasAudio ? 0.85 : 1.0))

        var audioFile: URL?
        if let audioTrack {
            let url = tempDir.appendingPathComponent("audio.mp4")
            try await downloadTrack(audioTrack, to: url, id: id, range: 0.85...1.0)
            audioFile = url
        }

        updateState(id, .merging, progress: 1.0)

        let folder = packageDirectory(titled: title)
        let output = folder.appendingPathComponent("video.mp4")
        try await MP4Remuxer.merge(video: videoFile, audio: audioFile, to: output)
        await finalize(id: id, folder: folder, mediaFile: "video.mp4",
                       source: source, title: title, qualityTitle: qualityTitle)
    }

    private func downloadMuxed(id: UUID, urlString: String, title: String,
                               qualityTitle: String, source: DownloadSource) async throws {
        updateState(id, .downloading, progress: 0)
        let folder = packageDirectory(titled: title)
        let output = folder.appendingPathComponent("video.mp4")
        let downloader = FileDownloader(destination: output) { [weak self] progress in
            Task { @MainActor in
                self?.updateProgress(id, value: progress)
            }
        }
        downloads[id] = downloader
        try await downloader.download(from: urlString)
        await finalize(id: id, folder: folder, mediaFile: "video.mp4",
                       source: source, title: title, qualityTitle: qualityTitle)
    }

    /// 下载完成后保存弹幕与元数据，并标记任务完成。
    private func finalize(id: UUID, folder: URL, mediaFile: String,
                          source: DownloadSource, title: String, qualityTitle: String) async {
        let mediaURL = folder.appendingPathComponent(mediaFile)
        let createdAt = tasks.first(where: { $0.id == id })?.createdAt ?? Date()

        // 弹幕下载失败不影响视频本身，记录 0 条即可。
        let danmaku = (try? await BiliClient.shared.fetchDanmaku(cid: source.cid)) ?? []
        let records = danmaku.map { item in
            RecordedDanmaku(t: item.time,
                            nickname: "",
                            text: item.text,
                            color: item.color,
                            mode: item.mode,
                            fontSize: item.fontSize)
        }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: folder.appendingPathComponent("danmaku.json"))
        }

        var duration: Double = 0
        if let length = try? await AVURLAsset(url: mediaURL).load(.duration),
           length.seconds.isFinite, length.seconds > 0 {
            duration = length.seconds
        }

        let meta = DownloadMeta(id: id,
                                title: title,
                                qualityTitle: qualityTitle,
                                createdAt: createdAt,
                                duration: duration,
                                danmakuCount: records.count,
                                mediaFile: mediaFile,
                                danmakuFile: "danmaku.json",
                                bvid: source.bvid,
                                cid: source.cid,
                                episodeID: source.episodeID)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: folder.appendingPathComponent("meta.json"))
        }
        finish(id, fileURL: mediaURL, danmakuCount: records.count)
    }

    private func downloadTrack(_ track: DashTrack, to destination: URL, id: UUID,
                               range: ClosedRange<Double>) async throws {
        var candidates: [String] = []
        if let url = track.url, !url.isEmpty { candidates.append(url) }
        candidates.append(contentsOf: track.backups)

        var lastError: Error?
        for candidate in candidates {
            guard !cancelled.contains(id), !Task.isCancelled else { throw CancellationError() }
            let downloader = FileDownloader(destination: destination) { [weak self] progress in
                let value = range.lowerBound + (range.upperBound - range.lowerBound) * progress
                Task { @MainActor in
                    self?.updateProgress(id, value: value)
                }
            }
            downloads[id] = downloader
            do {
                try await downloader.download(from: candidate)
                return
            } catch {
                if cancelled.contains(id) || Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError ?? BiliError.network("下载失败")
    }

    // MARK: - 轨道选择

    /// 取当前清晰度下兼容性最好的 AVC 轨（同等清晰度优先 H.264）。
    private func pickVideoTrack(_ dash: DashData, quality: Int) -> DashTrack? {
        let videos = dash.video ?? []
        guard !videos.isEmpty else { return nil }

        let targetID = videos.map { $0.id ?? 0 }.filter { $0 > 0 && $0 <= quality }.max()
            ?? videos.map { $0.id ?? 0 }.max() ?? 0
        let sameQuality = videos.filter { ($0.id ?? 0) == targetID }
        return sameQuality.first(where: { $0.codecid == 7 })
            ?? sameQuality.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) })
            ?? videos.first
    }

    /// 只选 AAC 音轨（FLAC/杜比无法写入 MP4），优先码率最高的一档。
    private func pickAudioTrack(_ dash: DashData) -> DashTrack? {
        let audios = dash.audio ?? []
        let aac = audios.filter { track in
            let id = track.id ?? 0
            return id == 30216 || id == 30232 || id == 30280
        }
        let pool = aac.isEmpty ? audios.filter({ ($0.id ?? 0) != 30250 && ($0.id ?? 0) != 30251 }) : aac
        return pool.max { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }
    }

    // MARK: - 状态与文件

    private func updateState(_ id: UUID, _ state: DownloadTaskItem.State, progress: Double) {
        guard var item = tasks.first(where: { $0.id == id }) else { return }
        item.state = state
        item.progress = progress
        update(item)
    }

    private func updateProgress(_ id: UUID, value: Double) {
        guard var item = tasks.first(where: { $0.id == id }), item.state == .downloading else { return }
        item.progress = min(1, max(item.progress, value))
        update(item)
    }

    private func finish(_ id: UUID, fileURL: URL, danmakuCount: Int = 0) {
        guard var item = tasks.first(where: { $0.id == id }) else { return }
        item.state = .finished
        item.progress = 1
        item.fileURL = fileURL
        item.danmakuCount = danmakuCount
        update(item)
    }

    private func update(_ item: DownloadTaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == item.id }) else { return }
        tasks[index] = item
    }

    private var downloadDirectory: URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("哔哩哔哩", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// 每个视频单独一个下载文件夹，内部保存 media、danmaku.json 与 meta.json。
    private func packageDirectory(titled title: String) -> URL {
        var name = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "视频" }
        if name.count > 60 { name = String(name.prefix(60)) }
        let stamp = Self.stampFormatter.string(from: Date())

        var url = downloadDirectory.appendingPathComponent("\(name)_\(stamp)", isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloadDirectory.appendingPathComponent("\(name)_\(stamp)_\(index)", isDirectory: true)
            index += 1
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - 单文件下载

/// 带进度的下载器：URLSession 下载临时文件后移动到目标地址。
final class FileDownloader: NSObject {
    private let destination: URL
    private let onProgress: (Double) -> Void

    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionTask?
    private var completed = false
    private let lock = NSLock()

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        super.init()
    }

    func download(from urlString: String) async throws {
        guard let url = URL(string: urlString) else { throw BiliError.invalidURL }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
            request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")

            let config = URLSessionConfiguration.default
            config.httpCookieStorage = HTTPCookieStorage.shared
            config.httpShouldSetCookies = true
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 3_600
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session

            let task = session.downloadTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        switch result {
        case .success: continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

extension FileDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            complete(.failure(BiliError.http(http.statusCode)))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            complete(.success(()))
        } catch {
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        complete(.failure(error))
    }
}

// MARK: - MP4 合成

/// 直接把 DASH 的 H.264/HEVC + AAC 编码样本重新封装成 MP4，不重新编码。
enum MP4Remuxer {
    static func merge(video videoURL: URL, audio audioURL: URL?, to outputURL: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw BiliError.decoding("视频轨读取失败")
        }
        let videoHint = try await videoTrack.load(.formatDescriptions).first

        var audioAsset: AVURLAsset?
        var audioTrack: AVAssetTrack?
        var audioHint: CMFormatDescription?
        if let audioURL {
            let asset = AVURLAsset(url: audioURL)
            if let track = try? await asset.loadTracks(withMediaType: .audio).first {
                audioAsset = asset
                audioTrack = track
                audioHint = try? await track.load(.formatDescriptions).first
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try remux(videoAsset: videoAsset, videoTrack: videoTrack, videoHint: videoHint,
                               audioAsset: audioAsset, audioTrack: audioTrack, audioHint: audioHint,
                               to: outputURL)
                    continuation.resume()
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func remux(videoAsset: AVURLAsset, videoTrack: AVAssetTrack,
                              videoHint: CMFormatDescription?,
                              audioAsset: AVURLAsset?, audioTrack: AVAssetTrack?,
                              audioHint: CMFormatDescription?,
                              to outputURL: URL) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoReader = try AVAssetReader(asset: videoAsset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard videoReader.canAdd(videoOutput) else {
            throw BiliError.decoding("无法读取视频轨")
        }
        videoReader.add(videoOutput)

        // MP4 直接封装必须提供格式提示，否则 AVAssetWriterInput 会抛异常。
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                            sourceFormatHint: videoHint)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw BiliError.decoding("无法写入视频轨")
        }
        writer.add(videoInput)

        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack, let audioAsset {
            let reader = try AVAssetReader(asset: audioAsset)
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                               sourceFormatHint: audioHint)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioReader = reader
                    audioOutput = output
                    audioInput = input
                }
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? BiliError.decoding("无法创建输出文件")
        }
        writer.startSession(atSourceTime: .zero)
        guard videoReader.startReading() else {
            writer.cancelWriting()
            throw videoReader.error ?? BiliError.decoding("视频解码失败")
        }
        audioReader?.startReading()

        let failure = FailureBox()
        let group = DispatchGroup()
        let videoJob = PumpJob(output: videoOutput, reader: videoReader, input: videoInput)

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do {
                try videoJob.run()
            } catch {
                failure.set(error)
                videoJob.cancel()
            }
        }

        if let audioOutput, let audioInput, let audioReader {
            let audioJob = PumpJob(output: audioOutput, reader: audioReader, input: audioInput)
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    try audioJob.run()
                } catch {
                    failure.set(error)
                    audioJob.cancel()
                }
            }
        }

        group.wait()

        if let error = failure.error {
            videoReader.cancelReading()
            audioReader?.cancelReading()
            writer.cancelWriting()
            throw error
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        guard writer.status == .completed else {
            throw writer.error ?? BiliError.decoding("视频合成失败")
        }
    }

    private static func pump(_ output: AVAssetReaderTrackOutput,
                             reader: AVAssetReader,
                             into input: AVAssetWriterInput) throws {
        while reader.status == .reading {
            if !input.isReadyForMoreMediaData {
                usleep(2_000)
                continue
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            if !input.append(sample) {
                throw BiliError.decoding("写入视频数据失败")
            }
        }
        if reader.status == .failed {
            throw reader.error ?? BiliError.decoding("读取视频数据失败")
        }
    }

    /// 单轨读写任务。持有 AVFoundation 对象并在独立线程执行，避免跨线程捕获告警。
    private final class PumpJob: @unchecked Sendable {
        private let output: AVAssetReaderTrackOutput
        private let reader: AVAssetReader
        private let input: AVAssetWriterInput

        init(output: AVAssetReaderTrackOutput, reader: AVAssetReader, input: AVAssetWriterInput) {
            self.output = output
            self.reader = reader
            self.input = input
        }

        func run() throws {
            try pump(output, reader: reader, into: input)
        }

        func cancel() {
            reader.cancelReading()
        }
    }

    /// 两个线程同时写轨时共享错误状态，避免捕获可变变量。
    private final class FailureBox {
        private let lock = NSLock()
        private var value: Error?

        func set(_ error: Error) {
            lock.lock()
            if value == nil { value = error }
            lock.unlock()
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
