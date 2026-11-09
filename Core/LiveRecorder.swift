import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import AppKit

/// 录制/下载时保存的一条弹幕，t 为相对开始播放的秒数。
struct RecordedDanmaku: Codable, Equatable {
    let t: Double
    let nickname: String
    let text: String
    let color: Int
    var mode: Int? = nil
    var fontSize: Double? = nil
}

/// 一条直播录制记录：每个录制是录制目录下的独立文件夹。
struct LiveRecording: Identifiable, Equatable {
    let baseName: String
    let title: String
    let roomID: Int
    let createdAt: Date
    let duration: Double
    let mediaExt: String
    let danmakuCount: Int
    /// 兼容旧版本直接放在录制根目录的文件。
    let legacy: Bool

    var id: String { legacy ? "\(baseName)#legacy" : baseName }

    var folderURL: URL {
        legacy ? LiveRecorder.directory
               : LiveRecorder.directory.appendingPathComponent(baseName, isDirectory: true)
    }

    var mediaURL: URL {
        legacy ? LiveRecorder.directory.appendingPathComponent("\(baseName).\(mediaExt)")
               : folderURL.appendingPathComponent("recording.\(mediaExt)")
    }

    var danmakuURL: URL {
        legacy ? LiveRecorder.directory.appendingPathComponent("\(baseName).json")
               : folderURL.appendingPathComponent("danmaku.json")
    }
}

/// 录制文件夹内的元数据。
struct RecordingSidecar: Codable {
    let title: String
    let roomID: Int
    let createdAt: Date
    let duration: Double
    let danmakuCount: Int
}

/// 旧版本扁平存放的弹幕文件。
private struct LegacyRecordingSidecar: Codable {
    let title: String
    let roomID: Int
    let createdAt: Date
    let duration: Double
    let danmaku: [RecordedDanmaku]
}

/// 直播录制：持续抓取 HLS 分片拼成 ts，结束后无损转封装为 mp4，并同步保存弹幕时间轴。
@MainActor
final class LiveRecorder: ObservableObject {
    static let shared = LiveRecorder()

    nonisolated static let directory: URL = {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return base.appendingPathComponent("哔哩哔哩/直播录制", isDirectory: true)
    }()

    /// 当前录制任务数：支持多个直播窗口同时录制。
    @Published private(set) var recordingCount = 0
    /// 每秒刷新一次，供界面显示各录制任务的计时。
    @Published private(set) var tick = Date()
    @Published private(set) var recordings: [LiveRecording] = []

    private var sessions: [UUID: Session] = [:]
    private var timerTask: Task<Void, Never>?

    private struct Session {
        let owner: UUID
        let roomID: Int
        let title: String
        let qn: Int
        let startedAt: Date
        let baseName: String
        let folder: URL
        let tsURL: URL
        var playlistURL: URL
        var task: Task<Void, Never>?
        var fileHandle: FileHandle?
        var danmaku: [RecordedDanmaku] = []
        var seenSegments: Set<String> = []
        var isFirstPoll = true
    }

    private init() {}

    // MARK: - 对外接口

    /// 该播放器是否正在录制。
    func isRecording(owner: UUID) -> Bool {
        sessions[owner] != nil
    }

    /// 该播放器的录制时长。
    func elapsed(for owner: UUID) -> Double {
        guard let started = sessions[owner]?.startedAt else { return 0 }
        return max(0, tick.timeIntervalSince(started))
    }

    /// 正在进行的录制任务，供录制列表展示。
    struct ActiveRecording: Identifiable {
        let id: UUID
        let title: String
        let startedAt: Date
    }

    var activeSessions: [ActiveRecording] {
        sessions.values
            .map { ActiveRecording(id: $0.owner, title: $0.title, startedAt: $0.startedAt) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func start(owner: UUID, roomID: Int, title: String, playlistURL: URL, qn: Int) {
        guard sessions[owner] == nil else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        loadRecordings()

        let stamp = Self.stampFormatter.string(from: Date())
        let baseName = "\(Self.sanitize(title))_\(stamp)"
        let folder = Self.uniqueFolder(named: baseName)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tsURL = folder.appendingPathComponent("recording.ts")
        FileManager.default.createFile(atPath: tsURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tsURL) else { return }

        // 录制开始就写入元数据：即使录制中途应用被强制退出，录制目录也能被列表识别。
        Self.writeMeta(in: folder,
                       title: title,
                       roomID: roomID,
                       createdAt: Date(),
                       duration: 0,
                       danmakuCount: 0)

        var newSession = Session(owner: owner,
                                 roomID: roomID,
                                 title: title,
                                 qn: qn,
                                 startedAt: Date(),
                                 baseName: baseName,
                                 folder: folder,
                                 tsURL: tsURL,
                                 playlistURL: playlistURL)
        newSession.fileHandle = handle
        sessions[owner] = newSession
        recordingCount = sessions.count
        tick = Date()
        sessions[owner]?.task = Task { [weak self] in await self?.pollLoop(owner: owner) }
        startTimerIfNeeded()
    }

    /// 停止录制并返回生成的记录；失败时返回 nil。
    @discardableResult
    func stop(owner: UUID) async -> LiveRecording? {
        guard var current = sessions[owner] else { return nil }
        sessions[owner] = nil
        recordingCount = sessions.count
        current.task?.cancel()
        await current.task?.value

        try? current.fileHandle?.close()
        current.fileHandle = nil

        let duration = Date().timeIntervalSince(current.startedAt)

        // 先落盘弹幕与元数据，再做转封装：转封装耗时且可能被退出打断，
        // 提前写入能保证录制一定出现在列表里（此时仍可直接回放 ts）。
        if let data = try? JSONEncoder().encode(current.danmaku) {
            try? data.write(to: current.folder.appendingPathComponent("danmaku.json"))
        }
        Self.writeMeta(in: current.folder,
                       title: current.title,
                       roomID: current.roomID,
                       createdAt: current.startedAt,
                       duration: duration,
                       danmakuCount: current.danmaku.count)

        // 先写到临时文件，成功后再原子替换，避免留下半截 mp4。
        let mp4URL = current.folder.appendingPathComponent("recording.mp4")
        let tempURL = current.folder.appendingPathComponent("recording.part.mp4")
        try? FileManager.default.removeItem(at: tempURL)
        var mediaExt = "ts"
        if (try? await LiveTSRemuxer.remux(current.tsURL, to: tempURL)) != nil {
            try? FileManager.default.removeItem(at: mp4URL)
            if (try? FileManager.default.moveItem(at: tempURL, to: mp4URL)) != nil {
                try? FileManager.default.removeItem(at: current.tsURL)
                mediaExt = "mp4"
            }
        }
        try? FileManager.default.removeItem(at: tempURL)

        let recording = LiveRecording(baseName: current.baseName,
                                      title: current.title,
                                      roomID: current.roomID,
                                      createdAt: current.startedAt,
                                      duration: duration,
                                      mediaExt: mediaExt,
                                      danmakuCount: current.danmaku.count,
                                      legacy: false)
        recordings.insert(recording, at: 0)
        return recording
    }

    private func startTimerIfNeeded() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.sessions.isEmpty { break }
                self.tick = Date()
            }
            self?.timerTask = nil
        }
    }

    func recordDanmaku(owner: UUID, roomID: Int, nickname: String, text: String, color: Int,
                       mode: Int = 1, fontSize: Double = 25) {
        guard var current = sessions[owner], current.roomID == roomID, !text.isEmpty else { return }
        let t = Date().timeIntervalSince(current.startedAt)
        current.danmaku.append(RecordedDanmaku(t: t,
                                               nickname: nickname,
                                               text: text,
                                               color: color,
                                               mode: mode,
                                               fontSize: fontSize))
        sessions[owner] = current
    }

    func loadRecordings() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: Self.directory,
                                                        includingPropertiesForKeys: [.isDirectoryKey]) else {
            recordings = []
            return
        }
        var result: [LiveRecording] = []
        for url in entries {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                // ts 与 mp4 同时存在说明上次转封装未完成，ts 才是完整内容。
                let ext: String
                if fm.fileExists(atPath: url.appendingPathComponent("recording.ts").path) {
                    ext = "ts"
                } else if fm.fileExists(atPath: url.appendingPathComponent("recording.mp4").path) {
                    ext = "mp4"
                } else {
                    continue
                }
                let sidecar: RecordingSidecar
                if let data = try? Data(contentsOf: url.appendingPathComponent("meta.json")),
                   let decoded = try? JSONDecoder().decode(RecordingSidecar.self, from: data) {
                    sidecar = decoded
                } else {
                    // meta.json 缺失（旧版本或写入前被中断）：用文件夹名与文件时间恢复基本信息。
                    let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                    sidecar = RecordingSidecar(title: Self.title(fromFolderName: url.lastPathComponent),
                                               roomID: 0,
                                               createdAt: created,
                                               duration: 0,
                                               danmakuCount: Self.danmakuCount(in: url))
                }
                let fileCount = Self.danmakuCount(in: url)
                result.append(LiveRecording(baseName: url.lastPathComponent,
                                            title: sidecar.title,
                                            roomID: sidecar.roomID,
                                            createdAt: sidecar.createdAt,
                                            duration: sidecar.duration,
                                            mediaExt: ext,
                                            danmakuCount: fileCount > 0 ? fileCount : sidecar.danmakuCount,
                                            legacy: false))
            } else if url.pathExtension == "json",
                      let data = try? Data(contentsOf: url),
                      let legacy = try? JSONDecoder().decode(LegacyRecordingSidecar.self, from: data) {
                // 旧版本：媒体与同名 json 直接放在录制根目录。
                let baseName = url.deletingPathExtension().lastPathComponent
                let ext: String
                if fm.fileExists(atPath: Self.directory.appendingPathComponent("\(baseName).mp4").path) {
                    ext = "mp4"
                } else if fm.fileExists(atPath: Self.directory.appendingPathComponent("\(baseName).ts").path) {
                    ext = "ts"
                } else {
                    continue
                }
                result.append(LiveRecording(baseName: baseName,
                                            title: legacy.title,
                                            roomID: legacy.roomID,
                                            createdAt: legacy.createdAt,
                                            duration: legacy.duration,
                                            mediaExt: ext,
                                            danmakuCount: legacy.danmaku.count,
                                            legacy: true))
            }
        }
        recordings = result.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ recording: LiveRecording) {
        if recording.legacy {
            try? FileManager.default.removeItem(at: recording.mediaURL)
            try? FileManager.default.removeItem(at: recording.danmakuURL)
        } else {
            try? FileManager.default.removeItem(at: recording.folderURL)
        }
        recordings.removeAll { $0.id == recording.id }
    }

    /// 读取录制文件夹中保存的弹幕时间轴。
    @MainActor
    static func danmaku(for recording: LiveRecording) -> [RecordedDanmaku] {
        guard let data = try? Data(contentsOf: recording.danmakuURL) else { return [] }
        if let list = try? JSONDecoder().decode([RecordedDanmaku].self, from: data) {
            return list
        }
        if let legacy = try? JSONDecoder().decode(LegacyRecordingSidecar.self, from: data) {
            return legacy.danmaku
        }
        return []
    }

    func revealDirectory() {
        NSWorkspace.shared.open(Self.directory)
    }

    // MARK: - 抓流

    private func pollLoop(owner: UUID) async {
        while !Task.isCancelled {
            guard sessions[owner] != nil else { return }
            do {
                try await pollOnce(owner: owner)
            } catch {
                // 地址过期或网络抖动：刷新一次播放地址后继续。
                await refreshPlaylistURL(owner: owner)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func pollOnce(owner: UUID) async throws {
        guard var current = sessions[owner] else { return }
        let data = try await fetch(current.playlistURL, roomID: current.roomID)
        guard let text = String(data: data, encoding: .utf8) else { return }

        // 主播放列表：跟随第一个子列表。
        if text.contains("#EXT-X-STREAM-INF") {
            if let variant = Self.firstURI(in: text, relativeTo: current.playlistURL) {
                current.playlistURL = variant
                sessions[owner] = current
            }
            return
        }

        var segments = Self.segmentURLs(in: text, relativeTo: current.playlistURL)
        guard !segments.isEmpty else { return }
        // 首次只取最后一片，避免把进入房间前的旧内容也录进去。
        if current.isFirstPoll {
            segments = [segments[segments.count - 1]]
            current.isFirstPoll = false
        }
        sessions[owner] = current

        for url in segments {
            let key = url.lastPathComponent
            guard var live = sessions[owner], !live.seenSegments.contains(key) else { continue }
            let chunk = try await fetch(url, roomID: live.roomID)
            live.seenSegments.insert(key)
            sessions[owner] = live
            try sessions[owner]?.fileHandle?.write(contentsOf: chunk)
        }
    }

    /// 播放地址带过期时间，失败时重新请求一次接口并替换为同清晰度的 ts 地址。
    private func refreshPlaylistURL(owner: UUID) async {
        guard var current = sessions[owner] else { return }
        guard let info = try? await BiliAPI.livePlayInfo(roomID: current.roomID, qn: current.qn) else { return }
        let candidates = BiliAPI.liveStreamCandidates(from: info)
        let preferred = candidates.filter { $0.format == "ts" }
        guard let raw = (preferred.first ?? candidates.first)?.url,
              let url = URL(string: raw) else { return }
        current.playlistURL = url
        current.isFirstPoll = false
        sessions[owner] = current
    }

    private func fetch(_ url: URL, roomID: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("https://live.bilibili.com/\(roomID)", forHTTPHeaderField: "Referer")
        request.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func segmentURLs(in text: String, relativeTo base: URL) -> [URL] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
            return URL(string: value, relativeTo: base)?.absoluteURL
        }
    }

    private static func firstURI(in text: String, relativeTo base: URL) -> URL? {
        for line in text.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("#") else { continue }
            return URL(string: value, relativeTo: base)?.absoluteURL
        }
        return nil
    }

    private static func writeMeta(in folder: URL, title: String, roomID: Int,
                                  createdAt: Date, duration: Double, danmakuCount: Int) {
        let sidecar = RecordingSidecar(title: title,
                                       roomID: roomID,
                                       createdAt: createdAt,
                                       duration: duration,
                                       danmakuCount: danmakuCount)
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(to: folder.appendingPathComponent("meta.json"))
    }

    /// 从「标题_yyyyMMdd-HHmmss」形式的文件夹名还原标题。
    private static func title(fromFolderName name: String) -> String {
        let pattern = "_[0-9]{8}-[0-9]{6}( \\([0-9]+\\))?$"
        if let range = name.range(of: pattern, options: .regularExpression) {
            let trimmed = String(name[..<range.lowerBound])
            return trimmed.isEmpty ? "直播录制" : trimmed
        }
        return name.isEmpty ? "直播录制" : name
    }

    private static func danmakuCount(in folder: URL) -> Int {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("danmaku.json")),
              let list = try? JSONDecoder().decode([RecordedDanmaku].self, from: data) else { return 0 }
        return list.count
    }

    private static func sanitize(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = title.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "直播录制" : String(cleaned.prefix(40))
    }

    /// 每个录制单独一个文件夹，重名时追加序号。
    private static func uniqueFolder(named name: String) -> URL {
        var url = directory.appendingPathComponent(name, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name) (\(index))", isDirectory: true)
            index += 1
        }
        return url
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// 把 HLS 的 ts 录制文件无损转封装为 mp4；两轨时间戳统一从 0 开始，保证回放进度正确。
enum LiveTSRemuxer {
    static func remux(_ input: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw BiliError.decoding("录制文件缺少视频轨")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let videoHint = try await videoTrack.load(.formatDescriptions).first
        let audioHint = try? await audioTrack?.load(.formatDescriptions).first

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try remuxSync(asset: asset,
                                  videoTrack: videoTrack,
                                  videoHint: videoHint,
                                  audioTrack: audioTrack,
                                  audioHint: audioHint,
                                  output: output)
                    continuation.resume()
                } catch {
                    try? FileManager.default.removeItem(at: output)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func remuxSync(asset: AVURLAsset,
                                  videoTrack: AVAssetTrack,
                                  videoHint: CMFormatDescription?,
                                  audioTrack: AVAssetTrack?,
                                  audioHint: CMFormatDescription?,
                                  output: URL) throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard videoReader.canAdd(videoOutput) else { throw BiliError.decoding("无法读取录制视频轨") }
        videoReader.add(videoOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: nil,
                                            sourceFormatHint: videoHint)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw BiliError.decoding("无法写入录制视频轨") }
        writer.add(videoInput)

        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack {
            let reader = try AVAssetReader(asset: asset)
            let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            trackOutput.alwaysCopiesSampleData = false
            if reader.canAdd(trackOutput) {
                reader.add(trackOutput)
                let input = AVAssetWriterInput(mediaType: .audio,
                                               outputSettings: nil,
                                               sourceFormatHint: audioHint)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioReader = reader
                    audioOutput = trackOutput
                    audioInput = input
                }
            }
        }

        guard videoReader.startReading() else {
            throw videoReader.error ?? BiliError.decoding("录制视频轨读取失败")
        }
        audioReader?.startReading()
        guard writer.startWriting() else {
            throw writer.error ?? BiliError.decoding("录制文件写入失败")
        }
        writer.startSession(atSourceTime: .zero)

        var videoSample = videoOutput.copyNextSampleBuffer()
        var audioSample = audioOutput?.copyNextSampleBuffer()

        var base = CMTime.invalid
        for sample in [videoSample, audioSample].compactMap({ $0 }) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isValid else { continue }
            base = base.isValid ? CMTimeMinimum(base, pts) : pts
        }
        guard base.isValid else { throw BiliError.decoding("录制文件没有可用画面") }

        while videoSample != nil || audioSample != nil {
            let takeVideo: Bool
            if let video = videoSample, let audio = audioSample {
                takeVideo = CMSampleBufferGetPresentationTimeStamp(video)
                    <= CMSampleBufferGetPresentationTimeStamp(audio)
            } else {
                takeVideo = videoSample != nil
            }

            if takeVideo, let sample = videoSample {
                waitUntilReady(videoInput)
                if let retimed = retimed(sample, offset: base) {
                    videoInput.append(retimed)
                }
                videoSample = videoOutput.copyNextSampleBuffer()
            } else if let sample = audioSample, let input = audioInput {
                waitUntilReady(input)
                if let retimed = retimed(sample, offset: base) {
                    input.append(retimed)
                }
                audioSample = audioOutput?.copyNextSampleBuffer()
            } else {
                audioSample = nil
            }
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        guard writer.status == .completed else {
            throw writer.error ?? BiliError.decoding("录制文件封装失败")
        }
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput) {
        while !input.isReadyForMoreMediaData {
            usleep(2_000)
        }
    }

    /// 把 ts 里以流启动时间为基准的 pts 平移到 0，避免 mp4 出现巨大起始时间。
    private static func retimed(_ sample: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0,
                                               arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sample }
        var infos = [CMSampleTimingInfo](repeating: .invalid, count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count,
                                               arrayToFill: &infos, entriesNeededOut: &count)
        for index in 0..<count {
            if infos[index].presentationTimeStamp.isValid {
                infos[index].presentationTimeStamp = CMTimeSubtract(infos[index].presentationTimeStamp, offset)
            }
            if infos[index].decodeTimeStamp.isValid {
                infos[index].decodeTimeStamp = CMTimeSubtract(infos[index].decodeTimeStamp, offset)
            }
        }
        var output: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: sample,
                                              sampleTimingEntryCount: count,
                                              sampleTimingArray: &infos,
                                              sampleBufferOut: &output)
        return output ?? sample
    }
}
