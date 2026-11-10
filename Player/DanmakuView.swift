import SwiftUI
import AppKit
import AVFoundation

struct DanmakuOverlay: View {
    let items: [DanmakuLaneItem]
    let time: Double
    let opacity: Double
    let fontSize: Double

    var body: some View {
        Canvas { context, size in
            let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: baseFont]
            let laneHeight = fontSize + 7
            let topInset: CGFloat = 10

            for entry in items {
                let elapsed = time - entry.item.time
                guard elapsed >= 0 else { continue }

                let text = entry.item.text
                let width = (text as NSString).size(withAttributes: attributes).width
                let color = Color(nsColor: entry.color).opacity(opacity)

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
                    draw(text: text, color: color, in: context,
                         at: CGPoint(x: x + width / 2, y: y + fontSize / 2))
                default:
                    let stay = Self.stay(for: text.count)
                    guard elapsed <= stay else { continue }
                    let travel = size.width + width
                    let x = size.width - (elapsed / stay) * travel
                    guard x + width > 0 else { continue }
                    let y = topInset + CGFloat(entry.lane) * laneHeight
                    draw(text: text, color: color, in: context,
                         at: CGPoint(x: x + width / 2, y: y + fontSize / 2))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(text: String, color: Color,
                      in context: GraphicsContext, at point: CGPoint) {
        var resolved = context
        resolved.addFilter(.shadow(color: .black.opacity(0.85), radius: 1.2, x: 0, y: 0))
        let label = Text(text)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(color)
        resolved.draw(label, at: point, anchor: .center)
    }

    static func stay(for count: Int) -> Double {
        min(12.0, 7.0 + Double(count) * 0.12)
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
