import Foundation

enum BiliError: LocalizedError {
    case invalidURL
    case http(Int)
    case api(code: Int, message: String)
    case decoding(String)
    case network(String)
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的请求地址"
        case .http(let code): return "网络请求失败（HTTP \(code)）"
        case .api(let code, let message):
            if code == -101 { return "请先登录" }
            if code == -352 { return "请求被风控拦截，请稍后重试" }
            if code == -404 { return "内容不存在或已被删除" }
            return message.isEmpty ? "接口错误（\(code)）" : message
        case .decoding(let message): return message.isEmpty ? "数据解析失败" : message
        case .network(let message): return message
        case .notLoggedIn: return "请先登录"
        }
    }
}

private struct WBIKeysImage: Decodable {
    let img_url: String?
    let sub_url: String?
}

private struct WBIKeysData: Decodable {
    let wbi_img: WBIKeysImage?
}

private struct WBIKeys {
    let imgKey: String
    let subKey: String
    let fetchedAt: Date
}

@MainActor
final class BiliClient {
    static let shared = BiliClient()

    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    nonisolated static let webReferer = "https://www.bilibili.com/"

    let session: URLSession
    private var wbiKeys: WBIKeys?
    private let cookieStoreKey = "bili.cookies.v1"

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        restoreCookies()
    }

    // MARK: - Cookie

    var isLoggedIn: Bool {
        cookieValue("SESSDATA")?.isEmpty == false
    }

    func cookieValue(_ name: String) -> String? {
        HTTPCookieStorage.shared.cookies?.first(where: { $0.name == name })?.value
    }

    func setCookie(name: String, value: String, domain: String = ".bilibili.com", secure: Bool = true) {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/"
        ]
        if secure { props[.secure] = "TRUE" }
        props[.expires] = Date().addingTimeInterval(60 * 60 * 24 * 365)
        if let cookie = HTTPCookie(properties: props) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    func persistCookies() {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        let payload = cookies.compactMap { cookie -> [String: String]? in
            guard cookie.domain.contains("bilibili") || cookie.domain.contains("biligame") || cookie.domain.contains("hdslb") else { return nil }
            return ["name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path]
        }
        UserDefaults.standard.set(payload, forKey: cookieStoreKey)
    }

    /// 跨域换票拿到的 Cookie 可能挂在 .biligame.com 下，统一补一份 .bilibili.com 的。
    func normalizeLoginCookies() {
        let names = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"]
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        for name in names {
            guard let source = cookies.first(where: { $0.name == name && $0.domain.contains("bilibili") })
                    ?? cookies.first(where: { $0.name == name && $0.domain.contains("biligame") }) else { continue }
            let exists = cookies.contains { $0.name == name && $0.domain.contains("bilibili.com") }
            if !exists {
                setCookie(name: name, value: source.value, domain: ".bilibili.com")
            }
        }
    }

    private func restoreCookies() {
        guard let payload = UserDefaults.standard.array(forKey: cookieStoreKey) as? [[String: String]] else { return }
        for item in payload {
            guard let name = item["name"], let value = item["value"] else { continue }
            let domain = item["domain"] ?? ".bilibili.com"
            setCookie(name: name, value: value, domain: domain)
        }
    }

    func clearLoginCookies() {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        UserDefaults.standard.removeObject(forKey: cookieStoreKey)
        wbiKeys = nil
    }

    // MARK: - 初始化

    func prepare() async {
        if cookieValue("buvid3") == nil {
            await fetchBuvid()
        }
        _ = try? await ensureWBIKeys()
    }

    private func fetchBuvid() async {
        guard let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") else { return }
        var request = makeRequest(url: url, referer: Self.webReferer)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any] else { return }
        if let b3 = payload["b_3"] as? String {
            setCookie(name: "buvid3", value: b3, domain: ".bilibili.com")
        }
        if let b4 = payload["b_4"] as? String {
            setCookie(name: "buvid4", value: b4, domain: ".bilibili.com")
        }
    }

    // MARK: - 请求

    func makeRequest(url: URL, referer: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        return request
    }

    func get<T: Decodable>(_ urlString: String,
                           params: [String: String] = [:],
                           referer: String = BiliClient.webReferer,
                           signed: Bool = false,
                           as type: T.Type = T.self) async throws -> T {
        let url = try await buildURL(urlString, params: params, signed: signed)
        var request = makeRequest(url: url, referer: referer)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BiliError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BiliError.http(http.statusCode)
        }
        do {
            let wrapper = try JSONDecoder().decode(BiliResponse<T>.self, from: data)
            if wrapper.code != 0 {
                throw BiliError.api(code: wrapper.code, message: wrapper.message ?? "")
            }
            guard let payload = wrapper.data else {
                throw BiliError.decoding("响应缺少 data")
            }
            persistCookies()
            return payload
        } catch let err as BiliError {
            throw err
        } catch {
            throw BiliError.decoding("数据解析失败")
        }
    }

    func getRaw(_ urlString: String, params: [String: String] = [:], referer: String) async throws -> Data {
        let url = try await buildURL(urlString, params: params, signed: false)
        let request = makeRequest(url: url, referer: referer)
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw BiliError.http(http.statusCode)
            }
            return data
        } catch let err as BiliError {
            throw err
        } catch {
            throw BiliError.network(error.localizedDescription)
        }
    }

    /// 表单 POST（自动带 Cookie 与 csrf），用于上报观看进度等写操作；返回接口 code。
    @discardableResult
    func postForm(_ urlString: String,
                  params: [String: String] = [:],
                  referer: String = BiliClient.webReferer) async throws -> Int {
        guard isLoggedIn else { return -101 }
        guard let url = URL(string: urlString) else { throw BiliError.invalidURL }
        var request = makeRequest(url: url, referer: referer, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = params
        if let csrf = cookieValue("bili_jct") {
            fields["csrf"] = csrf
        }
        request.httpBody = Self.formBody(fields).data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BiliError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BiliError.http(http.statusCode)
        }
        persistCookies()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["code"] as? Int) ?? -1
    }

    private static func formBody(_ fields: [String: String]) -> String {
        fields.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
            return "\(key)=\(encoded)"
        }
        .joined(separator: "&")
    }

    private func buildURL(_ urlString: String, params: [String: String], signed: Bool) async throws -> URL {
        guard var components = URLComponents(string: urlString) else {
            throw BiliError.invalidURL
        }
        var allParams = params
        if signed {
            let keys = try await ensureWBIKeys()
            allParams = WBISigner.sign(params: params, imgKey: keys.imgKey, subKey: keys.subKey)
        }
        if !allParams.isEmpty {
            let existing = components.queryItems ?? []
            components.queryItems = existing + allParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw BiliError.invalidURL }
        return url
    }

    private func ensureWBIKeys() async throws -> WBIKeys {
        if let keys = wbiKeys, Date().timeIntervalSince(keys.fetchedAt) < 600 {
            return keys
        }
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else {
            throw BiliError.invalidURL
        }
        let request = makeRequest(url: url, referer: Self.webReferer)
        let (data, _) = try await session.data(for: request)
        guard let wrapper = try? JSONDecoder().decode(BiliResponse<WBIKeysData>.self, from: data),
              let image = wrapper.data?.wbi_img,
              let imgURL = image.img_url,
              let subURL = image.sub_url else {
            throw BiliError.decoding("无法获取 WBI 密钥")
        }
        let imgKey = imgURL.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? ""
        let subKey = subURL.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? ""
        let keys = WBIKeys(imgKey: imgKey, subKey: subKey, fetchedAt: Date())
        wbiKeys = keys
        return keys
    }

    // MARK: - 弹幕

    func fetchDanmaku(cid: Int) async throws -> [DanmakuItem] {
        let data = try await getRaw("https://api.bilibili.com/x/v1/dm/list.so",
                                    params: ["oid": String(cid)],
                                    referer: "https://www.bilibili.com/")
        let parser = DanmakuXMLParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.items
    }
}

// MARK: - 弹幕解析

private final class DanmakuXMLParser: NSObject, XMLParserDelegate {
    var items: [DanmakuItem] = []
    private var currentAttributes: String?
    private var currentText: String = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard elementName == "d" else { return }
        currentAttributes = attributeDict["p"]
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "d", let attrs = currentAttributes else { return }
        let fields = attrs.components(separatedBy: ",")
        guard fields.count >= 4,
              let time = Double(fields[0]),
              let mode = Int(fields[1]),
              let color = Int(fields[3]) else {
            currentAttributes = nil
            return
        }
        let font = fields.count >= 4 ? 25.0 : 25.0
        items.append(DanmakuItem(time: time, mode: mode, color: color, text: currentText, fontSize: font))
        currentAttributes = nil
        currentText = ""
    }
}
