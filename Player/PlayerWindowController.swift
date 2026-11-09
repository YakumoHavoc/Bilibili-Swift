import AppKit
import SwiftUI

@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    static let shared = PlayerWindowController()

    private var window: NSWindow?
    private var currentViewModel: PlayerViewModel?
    private var keyMonitor: Any?

    override init() {
        super.init()
        // 空格与键盘媒体键（播放/暂停）控制播放器；仅播放器窗口为前台时生效。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            // NSEvent 不是 Sendable，只把基本类型传入主线程判断，避免跨隔离域捕获。
            let type = event.type.rawValue
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.rawValue
            let subtype = event.subtype.rawValue
            let data1 = event.data1
            let consumed = MainActor.assumeIsolated {
                self?.handleShortcut(type: type,
                                     keyCode: keyCode,
                                     modifiers: modifiers,
                                     subtype: subtype,
                                     data1: data1) ?? false
            }
            return consumed ? nil : event
        }
    }

    /// 返回 true 表示该按键已被播放器消费。
    private func handleShortcut(type: UInt, keyCode: UInt16, modifiers: UInt,
                                subtype: Int16, data1: Int) -> Bool {
        guard let window, window.isKeyWindow, window.attachedSheet == nil else { return false }
        // 避免拦截输入框/菜单中的按键。
        if window.firstResponder is NSText { return false }
        guard let viewModel = currentViewModel else { return false }

        if type == NSEvent.EventType.keyDown.rawValue {
            let flags = NSEvent.ModifierFlags(rawValue: modifiers)
            guard keyCode == 49,
                  flags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return false
            }
            viewModel.togglePlay()
            return true
        }

        // 系统媒体键：subtype 8 为辅助控制键，keyCode 16 为播放/暂停。
        guard subtype == 8 else { return false }
        let mediaKeyCode = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0x0000FF00) >> 8
        guard mediaKeyCode == 16, keyState == 0x0A else { return false }
        viewModel.togglePlay()
        return true
    }

    func open(video: VideoCard, app: AppState) {
        guard let identifier = video.bvid ?? video.aid.map({ "av\($0)" }) else {
            app.showToast("无法播放该视频")
            return
        }
        open(identifier: identifier, title: video.title, app: app)
    }

    func open(identifier: String, title: String, app: AppState) {
        present(mode: .video(identifier: identifier), title: title, app: app)
    }

    func openEpisode(epID: Int, title: String, app: AppState) {
        present(mode: .episode(epID: epID), title: title, app: app)
    }

    func openLive(room: LiveRoom, app: AppState) {
        present(mode: .live(roomID: room.id), title: room.title, app: app)
    }

    func openRecording(_ recording: LiveRecording, app: AppState) {
        present(mode: .recording(recording), title: recording.title, app: app)
    }

    private func present(mode: PlaybackMode, title: String, app: AppState) {
        currentViewModel?.stop()

        let viewModel = PlayerViewModel(mode: mode,
                                        title: title.isEmpty ? "哔哩哔哩" : title,
                                        quality: app.playQuality)
        currentViewModel = viewModel

        let root = PlayerView(viewModel: viewModel)
            .environmentObject(app)
        let hosting = NSHostingView(rootView: root)

        if let window {
            window.contentView = hosting
            window.title = title.isEmpty ? "哔哩哔哩" : title
            window.makeKeyAndOrderFront(nil)
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = title.isEmpty ? "哔哩哔哩" : title
            newWindow.titleVisibility = .visible
            newWindow.minSize = NSSize(width: 900, height: 620)
            newWindow.isReleasedWhenClosed = false
            newWindow.backgroundColor = NSColor.black
            newWindow.contentView = hosting
            newWindow.delegate = self
            newWindow.center()
            window = newWindow
            newWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        currentViewModel?.stop()
    }
}
