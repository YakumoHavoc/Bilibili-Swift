import SwiftUI

@main
struct BilibiliApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(app)
                .frame(minWidth: 980, minHeight: 640)
                .id(app.uiFontScale)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("刷新") {
                    app.refreshToken += 1
                }
                .keyboardShortcut("r")
                Button("回到首页") {
                    app.navigate(.home)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }
}
