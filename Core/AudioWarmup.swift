import AVFoundation
import Foundation

/// 进程内第一次播放声音时，CoreAudio 需要初始化输出设备与音频驱动，耗时可达数秒，
/// 表现为「首次打开视频声音延迟，之后再打开就正常」。启动时先静音跑一小段音频，
/// 把音频设备提前拉起，之后进入播放器声音即可与画面同步。
actor AudioWarmup {
    static let shared = AudioWarmup()

    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?

    /// 启动预热：静音循环播放 20 秒后自动释放音频设备。
    func start() async {
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)

        let hardwareFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let format: AVAudioFormat
        if hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 {
            format = hardwareFormat
        } else if let fallback = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) {
            format = fallback
        } else {
            return
        }

        engine.connect(node, to: engine.mainMixerNode, format: format)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
            return
        }
        buffer.frameLength = buffer.frameCapacity

        // 显式清零，保证预热期间完全静音。
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in buffers {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }

        do {
            try engine.start()
        } catch {
            return
        }

        scheduleSilentLoop(buffer, on: node)
        node.play()
        self.engine = engine
        self.node = node

        // 设备已拉起即可，无需长期占用音频设备。
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        stop()
    }

    /// 放在同步方法里调度，避免命中异步重载（异步版本会等到播放结束才返回）。
    private func scheduleSilentLoop(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode) {
        node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    func stop() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
    }
}
