import AppKit

actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
        cache.countLimit = 400
        cache.totalCostLimit = 120 * 1024 * 1024
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
            cache.setObject(image, forKey: key, cost: image.tiffRepresentation?.count ?? 0)
        }
        return image
    }

    func clear() {
        cache.removeAllObjects()
        inFlight.removeAll()
    }
}
