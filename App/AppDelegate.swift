import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private static let playerWindowIdentifier = "BilibiliPlayerWindow"

    /// 主窗口弱引用：关闭按钮只隐藏窗口，点击 Dock 图标可以再次显示。
    private weak var mainWindow: NSWindow?
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // 预热音频设备，消除进程内首次播放的声音延迟。
        Task { await AudioWarmup.shared.start() }

        // 主窗口上的 Cmd+W 也做隐藏处理，保证之后能从 Dock 重新打开。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isCommandW = event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "w"
            let handled = MainActor.assumeIsolated {
                self?.hideMainWindowIfNeeded(isCommandW: isCommandW) ?? false
            }
            return handled ? nil : event
        }

        DispatchQueue.main.async {
            self.configureMainWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        configureMainWindow()
    }

    /// MainView 所在窗口注册为主窗口（设置等其它窗口不参与）。
    func registerMainWindow(_ window: NSWindow) {
        if mainWindow !== window {
            mainWindow = window
        }
        configureMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点击 Dock 图标：主窗口被隐藏时重新显示（即使播放窗口仍然存在）。
    /// 由这里自行处理并返回 false，避免 SwiftUI 再新建一个主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let mainWindow {
            if mainWindow.isMiniaturized {
                mainWindow.deminiaturize(nil)
            }
            if !mainWindow.isVisible {
                mainWindow.makeKeyAndOrderFront(nil)
            }
        } else {
            for window in sender.windows where window.identifier?.rawValue != Self.playerWindowIdentifier
                && window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return false
    }

    /// 主窗口关闭按钮：隐藏窗口而不是销毁，避免播放窗口存在时无法从 Dock 恢复。
    @objc private func hideMainWindow(_ sender: Any?) {
        guard let window = (sender as? NSView)?.window else { return }
        window.orderOut(nil)
    }

    /// 拦截主窗口上的 Cmd+W，按关闭按钮同等逻辑隐藏窗口。
    private func hideMainWindowIfNeeded(isCommandW: Bool) -> Bool {
        guard isCommandW,
              let window = mainWindow,
              window.isKeyWindow,
              window.attachedSheet == nil else { return false }
        if window.firstResponder is NSText { return false }
        window.orderOut(nil)
        return true
    }

    /// 只对已注册的主窗口应用外观与关闭行为，避免把设置等窗口误当成主窗口。
    private func configureMainWindow() {
        guard let window = mainWindow,
              window.identifier?.rawValue != Self.playerWindowIdentifier else { return }
        window.title = "哔哩哔哩"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 980, height: 640)
        window.backgroundColor = NSColor.dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x17181A))
        window.isReleasedWhenClosed = false
        if let closeButton = window.standardWindowButton(.closeButton),
           closeButton.action != #selector(hideMainWindow(_:)) {
            closeButton.target = self
            closeButton.action = #selector(hideMainWindow(_:))
        }
    }
}
