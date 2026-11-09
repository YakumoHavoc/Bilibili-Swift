import AppKit
import SwiftUI

@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    static let shared = PlayerWindowController()

    /// 最多同时存在的播放窗口数（视频、直播共用）。
    static let maxWindows = 3
    /// 播放窗口标识：主窗口配置时据此跳过播放器窗口。
    static let windowIdentifier = NSUserInterfaceItemIdentifier("BilibiliPlayerWindow")

    private final class PlayerWindow {
        let window: NSWindow
        let viewModel: PlayerViewModel

        init(window: NSWindow, viewModel: PlayerViewModel) {
            self.window = window
            self.viewModel = viewModel
        }
    }

    private var windows: [PlayerWindow] = []
    private var keyMonitor: Any?

    override init() {
        super.init()
        // 空格与键盘媒体键（播放/暂停）控制播放器；仅当前活动的播放器窗口生效。
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
        guard let target = windows.first(where: { $0.window.isKeyWindow }),
              target.window.attachedSheet == nil else { return false }
        // 避免拦截输入框/菜单中的按键。
        if target.window.firstResponder is NSText { return false }
        let viewModel = target.viewModel

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
        guard windows.count < Self.maxWindows else {
            app.showToast("最多同时播放 \(Self.maxWindows) 个窗口，请先关闭一个")
            return
        }

        let displayTitle = title.isEmpty ? "哔哩哔哩" : title
        let viewModel = PlayerViewModel(mode: mode,
                                        title: displayTitle,
                                        quality: app.playQuality)
        let root = PlayerView(viewModel: viewModel)
            .environmentObject(app)
        let hosting = NSHostingView(rootView: root)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = displayTitle
        newWindow.titleVisibility = .visible
        newWindow.identifier = Self.windowIdentifier
        newWindow.minSize = NSSize(width: 900, height: 620)
        newWindow.isReleasedWhenClosed = false
        newWindow.backgroundColor = NSColor.black
        newWindow.contentView = hosting
        newWindow.delegate = self
        newWindow.center()
        // 多窗口时依次错开，避免完全重叠。
        if !windows.isEmpty {
            let offset = CGFloat(windows.count) * 28
            newWindow.setFrameOrigin(NSPoint(x: newWindow.frame.origin.x + offset,
                                             y: newWindow.frame.origin.y - offset))
        }

        windows.append(PlayerWindow(window: newWindow, viewModel: viewModel))
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
              let index = windows.firstIndex(where: { $0.window === closing }) else { return }
        let session = windows.remove(at: index)
        session.viewModel.stop()
        // 关闭窗口后释放 SwiftUI 内容树与播放器数据，避免常驻内存。
        closing.contentView = nil
    }
}
