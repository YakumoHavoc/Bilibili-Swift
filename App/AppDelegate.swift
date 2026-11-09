import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // 预热音频设备，消除进程内首次播放的声音延迟。
        Task { await AudioWarmup.shared.start() }
        DispatchQueue.main.async {
            self.configureWindows()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        configureWindows()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureWindows() {
        for window in NSApp.windows where window.canBecomeMain {
            window.title = "哔哩哔哩"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.minSize = NSSize(width: 980, height: 640)
            window.backgroundColor = NSColor.dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x17181A))
            window.isReleasedWhenClosed = false
        }
    }
}
