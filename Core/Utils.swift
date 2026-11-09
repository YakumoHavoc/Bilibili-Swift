import Foundation

enum ImageURL {
    static func fix(_ raw: String?) -> String {
        guard var value = raw, !value.isEmpty else { return "" }
        if value.hasPrefix("//") {
            value = "https:" + value
        }
        if value.hasPrefix("http://") {
            value = "https://" + value.dropFirst("http://".count)
        }
        return value
    }

    /// B 站图片支持按尺寸裁剪，列表页用小图可显著降低流量
    static func thumb(_ raw: String?, width: Int = 480, height: Int = 270) -> String {
        let url = fix(raw)
        guard !url.isEmpty else { return "" }
        return "\(url)@\(width)w_\(height)h_1c.webp"
    }
}

enum Fmt {
    static func count(_ value: Int) -> String {
        switch value {
        case ..<0:
            return "0"
        case 0..<10_000:
            return "\(value)"
        case 10_000..<100_000_000:
            let wan = Double(value) / 10_000
            return wan >= 10 ? String(format: "%.0f万", wan) : String(format: "%.1f万", wan)
        default:
            let yi = Double(value) / 100_000_000
            return String(format: "%.1f亿", yi)
        }
    }

    static func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "00:00" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    static func durationString(_ raw: String?) -> Int {
        guard let raw, !raw.isEmpty else { return 0 }
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }

    static func relativeDate(_ timestamp: Int) -> String {
        guard timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let now = Date()
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "刚刚" }
        if delta < 3600 { return "\(Int(delta / 60))分钟前" }
        if delta < 86400 { return "\(Int(delta / 3600))小时前" }
        if delta < 86400 * 30 { return "\(Int(delta / 86400))天前" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func fullDate(_ timestamp: Int) -> String {
        guard timestamp > 0 else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    static func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    static func score(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw != "0.0" else { return "" }
        if let value = Double(raw), value > 0 { return String(format: "%.1f", value) }
        return ""
    }
}
