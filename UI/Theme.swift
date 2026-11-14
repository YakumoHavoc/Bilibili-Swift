import SwiftUI
import AppKit

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension NSColor {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

enum Palette {
    static let pink = Color(nsColor: .dynamic(light: NSColor(hex: 0xFB7299), dark: NSColor(hex: 0xD44E7D)))
    static let pinkStrong = Color(hex: 0xFB7299)
    static let blue = Color(hex: 0x00AEEC)

    static let bg = Color(nsColor: .dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x17181A)))
    static let bgThin = Color(nsColor: .dynamic(light: NSColor(hex: 0xF6F7F8), dark: NSColor(hex: 0x1E2022)))
    static let bgRegular = Color(nsColor: .dynamic(light: NSColor(hex: 0xF1F2F3), dark: NSColor(hex: 0x232527)))
    static let bgThick = Color(nsColor: .dynamic(light: NSColor(hex: 0xE3E5E7), dark: NSColor(hex: 0x2F3134)))

    static let text1 = Color(nsColor: .dynamic(light: NSColor(hex: 0x18191C), dark: NSColor(hex: 0xE7E9EB)))
    static let text2 = Color(nsColor: .dynamic(light: NSColor(hex: 0x61666D), dark: NSColor(hex: 0xA2A7AE)))
    static let text3 = Color(nsColor: .dynamic(light: NSColor(hex: 0x9499A0), dark: NSColor(hex: 0x757A81)))

    static let line = Color(nsColor: .dynamic(light: NSColor(hex: 0xE3E5E7), dark: NSColor(hex: 0x2F3134)))
    static let hover = Color(nsColor: .dynamic(light: NSColor(hex: 0xF1F2F3), dark: NSColor(hex: 0x232527)))

    static let navBackground = Color(nsColor: .dynamic(light: NSColor(hex: 0xF6F7F8), dark: NSColor(hex: 0x1E2022)))
    static let windowBackground = Color(nsColor: .dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x17181A)))
}

enum Metrics {
    static let sidebarWidth: CGFloat = 76
    static let topBarHeight: CGFloat = 56
    static let contentPadding: CGFloat = 28
    static let cardRadius: CGFloat = 8
}

/// 界面字体缩放：设置中可调，所有界面文字统一按此比例缩放。
enum UIFontScale {
    /// 可选档位：小、标准、大。
    static let options: [Double] = [0.9, 1.0, 1.15]

    static var current: CGFloat = 1

    static func title(for value: Double) -> String {
        switch value {
        case ..<0.95: return "小"
        case ..<1.1: return "标准"
        default: return "大"
        }
    }
}

extension Font {
    /// 按当前界面缩放比例创建系统字体。
    static func ui(_ size: CGFloat,
                   weight: Font.Weight = .regular,
                   design: Font.Design = .default) -> Font {
        .system(size: size * UIFontScale.current, weight: weight, design: design)
    }
}
