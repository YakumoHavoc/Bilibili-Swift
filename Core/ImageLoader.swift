import AppKit

actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
        cache.countLimit = 300
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func load(_ urlString: String) async -> NSImage? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        let key = urlString as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let task = inFlight[urlString] {
            return await task.value
        }
        let task = Task<NSImage?, Never> {
            var request = URLRequest(url: url)
            request.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = NSImage(data: data) else {
                return nil
            }
            return image
        }
        inFlight[urlString] = task
        let image = await task.value
        inFlight[urlString] = nil
        if let image {
            // 用像素占用估算成本，避免 tiffRepresentation 的额外编码开销。
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    func clear() {
        cache.removeAllObjects()
        inFlight.removeAll()
    }
}
