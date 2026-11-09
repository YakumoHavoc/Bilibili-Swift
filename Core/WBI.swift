import Foundation
import CryptoKit

enum WBISigner {
    /// B 站 WBI 签名使用的字符重排表
    private static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52
    ]

    static func mixinKey(imgKey: String, subKey: String) -> String {
        let raw = Array(imgKey + subKey)
        let shuffled = mixinKeyEncTab.compactMap { index -> Character? in
            guard index < raw.count else { return nil }
            return raw[index]
        }
        return String(shuffled.prefix(32))
    }

    static func sign(params: [String: String], imgKey: String, subKey: String) -> [String: String] {
        let mixin = mixinKey(imgKey: imgKey, subKey: subKey)
        var signed = params
        signed["wts"] = String(Int(Date().timeIntervalSince1970))
        let sorted = signed.sorted { $0.key < $1.key }
        let query = sorted.map { key, value in
            "\(percentEncode(key))=\(percentEncode(filtered(value)))"
        }.joined(separator: "&")
        let md5 = Insecure.MD5.hash(data: Data((query + mixin).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        signed["w_rid"] = md5
        return signed
    }

    /// 过滤 !'()* 字符，并按 RFC 3986 编码
    private static func filtered(_ value: String) -> String {
        value.filter { !"!'()*".contains($0) }
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
