import SwiftUI
import AppKit
import AVFoundation

/// 弹幕层：单独观察播放时钟，避免进度每 30ms 更新一次时带动整个播放页重绘。
struct DanmakuLayer: View {
    let items: [DanmakuLaneItem]
    @ObservedObject var clock: PlaybackClock
    let opacity: Double
    let fontSize: Double

    var body: some View {
        DanmakuOverlay(items: items,
                       time: clock.time,
                       opacity: opacity,
                       fontSize: fontSize)
    }
}

struct DanmakuOverlay: View {
    let items: [DanmakuLaneItem]
    let time: Double
    let opacity: Double
    let fontSize: Double

    var body: some View {
        Canvas { context, size in
            // 阴影对所有弹幕完全一致：整体加一次，避免逐条复制上下文并创建滤镜。
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.85), radius: 1.2, x: 0, y: 0))

            for glyph in Self.glyphs(items: items, time: time, size: size, fontSize: fontSize, opacity: opacity) {
                draw(text: glyph.text, color: glyph.color, in: &shadowed, at: glyph.center)
            }
        }
        .allowsHitTesting(false)
        .overlay {
            DanmakuRightClickHandler { point, size in
                Self.hitTest(point: point, size: size, items: items, time: time, fontSize: fontSize)
            }
        }
    }

    /// 一条弹幕在画布上的位置与样式，绘制与右键命中检测共用同一份布局结果。
    struct Glyph {
        let text: String
        let color: Color
        let center: CGPoint
        let width: CGFloat
    }

    static func glyphs(items: [DanmakuLaneItem], time: Double,
                       size: CGSize, fontSize: Double, opacity: Double) -> [Glyph] {
        let laneHeight = fontSize + 7
        let topInset: CGFloat = 10
        var result: [Glyph] = []
        // 弹幕按时间升序排列，只遍历仍可能显示在屏幕上的那一段（通常几十条）。
        for entry in items[Self.activeRange(in: items, at: time)] {
            guard entry.item.time <= time else { break }
            let elapsed = time - entry.item.time

            let text = entry.item.text
            let width = DanmakuWidthCache.shared.width(of: text, fontSize: fontSize)
            let color = Color(nsColor: entry.color).opacity(opacity)
            let center: CGPoint

            switch entry.item.mode {
            case 4, 5:
                guard elapsed <= 4.5 else { continue }
                let x = (size.width - width) / 2
                let y: CGFloat
                if entry.item.mode == 5 {
                    y = topInset + CGFloat(entry.lane) * laneHeight
                } else {
                    y = size.height - 12 - CGFloat(entry.lane + 1) * laneHeight
                }
                center = CGPoint(x: x + width / 2, y: y + fontSize / 2)
            default:
                let stay = Self.stay(for: text.count)
                guard elapsed <= stay else { continue }
                let travel = size.width + width
                let x = size.width - (elapsed / stay) * travel
                guard x + width > 0 else { continue }
                let y = topInset + CGFloat(entry.lane) * laneHeight
                center = CGPoint(x: x + width / 2, y: y + fontSize / 2)
            }
            result.append(Glyph(text: text, color: color, center: center, width: width))
        }
        return result
    }

    /// 返回鼠标位置下最上层的弹幕文字。
    static func hitTest(point: CGPoint, size: CGSize, items: [DanmakuLaneItem],
                        time: Double, fontSize: Double) -> String? {
        let height = fontSize * 1.35
        for glyph in glyphs(items: items, time: time, size: size, fontSize: fontSize, opacity: 1).reversed() {
            let rect = CGRect(x: glyph.center.x - glyph.width / 2,
                              y: glyph.center.y - height / 2,
                              width: glyph.width, height: height)
            if rect.contains(point) { return glyph.text }
        }
        return nil
    }

    private func draw(text: String, color: Color,
                      in context: inout GraphicsContext, at point: CGPoint) {
        let label = Text(text)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(color)
        context.draw(label, at: point, anchor: .center)
    }

    /// 二分查找仍可能停留在屏幕上的第一条弹幕（最长停留 13 秒）。
    private static func activeRange(in items: [DanmakuLaneItem], at time: Double) -> Range<Int> {
        let threshold = time - 13
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].item.time < threshold {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low..<items.count
    }

    static func stay(for count: Int) -> Double {
        min(12.0, 7.0 + Double(count) * 0.12)
    }
}

/// 弹幕右键菜单：命中某条弹幕后提供「复制弹幕」。
private struct DanmakuRightClickHandler: NSViewRepresentable {
    let lookup: (CGPoint, CGSize) -> String?

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.lookup = lookup
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.lookup = lookup
    }

    final class CatcherView: NSView {
        var lookup: ((CGPoint, CGSize) -> String?)?
        private var monitor: Any?

        /// 只监听右键，不参与普通点击的命中，避免挡住播放器的点击操作。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return MainActor.assumeIsolated { self.handle(event) }
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), let text = lookup?(point, bounds.size) else { return event }
            let menu = NSMenu()
            let item = NSMenuItem(title: "复制弹幕", action: #selector(copyDanmaku(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = text
            menu.addItem(item)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }

        @objc private func copyDanmaku(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// 弹幕文字宽度缓存：每帧对每条弹幕做一次排版测量开销很大，这里按「字号 + 文本」缓存。
private final class DanmakuWidthCache {
    static let shared = DanmakuWidthCache()

    private var widths: [String: CGFloat] = [:]
    private let lock = NSLock()

    func width(of text: String, fontSize: Double) -> CGFloat {
        let key = "\(fontSize)-\(text)"
        lock.lock()
        defer { lock.unlock() }
        if let width = widths[key] { return width }
        let width = (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .medium)
        ]).width
        widths[key] = width
        return width
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.setPlayer(player)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.setPlayer(player)
    }

    final class PlayerLayerView: NSView {
        private let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            // 作为子图层加入，而不是直接充当视图的 backing layer：
            // 后者会脱离 SwiftUI 的层级与裁剪，播放区缩小时画面会溢出到下方。
            layer?.masksToBounds = true
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func setPlayer(_ player: AVPlayer) {
            if playerLayer.player !== player {
                playerLayer.player = player
            }
        }
    }
}
