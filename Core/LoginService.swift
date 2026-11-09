import Foundation
import AppKit
import CoreImage

@MainActor
final class LoginService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case waiting
        case scanned
        case confirmed
        case expired
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var qrImage: NSImage?
    @Published var qrURL: String?

    private var pollTask: Task<Void, Never>?
    private var qrcodeKey: String?

    func start() {
        if phase == .loading { return }
        if qrcodeKey != nil, phase == .waiting || phase == .scanned { return }
        stop()
        phase = .loading
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let generated = try await Self.generateQRCode()
                guard !Task.isCancelled else { return }
                self.qrcodeKey = generated.key
                self.qrURL = generated.url
                self.qrImage = Self.renderQRCode(generated.url)
                self.phase = .waiting
                await self.poll()
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        guard let key = qrcodeKey else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            guard let url = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=\(key)&source=main-fe-header") else { return }
            var request = BiliClient.shared.makeRequest(url: url, referer: "https://passport.bilibili.com/")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, _) = try? await BiliClient.shared.session.data(for: request),
                  let wrapper = try? JSONDecoder().decode(BiliResponse<QRPollData>.self, from: data),
                  let payload = wrapper.data else {
                continue
            }
            switch payload.code {
            case 0:
                if let loginURL = payload.url.flatMap(URL.init(string:)) {
                    await Self.redeemLoginCookies(from: loginURL)
                    BiliClient.shared.normalizeLoginCookies()
                }
                BiliClient.shared.persistCookies()
                phase = .confirmed
                return
            case 86101:
                phase = .waiting
            case 86090:
                phase = .scanned
            case 86038:
                phase = .expired
                return
            default:
                phase = .failed(payload.message ?? "登录失败")
                return
            }
        }
    }

    // MARK: - 二维码

    /// 扫码确认后，轮询返回的是带 ticket 的跨域地址；需再访问一次才会下发 SESSDATA 等 Cookie。
    private static func redeemLoginCookies(from url: URL) async {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var ticket: String?
        var goURL = "https://www.bilibili.com"
        for item in items {
            switch item.name {
            case "ticket":
                ticket = item.value
            case "gourl":
                if let value = item.value, !value.isEmpty { goURL = value }
            case "SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid":
                if let value = item.value, !value.isEmpty {
                    BiliClient.shared.setCookie(name: item.name, value: value)
                }
            default:
                break
            }
        }
        guard let ticket, !ticket.isEmpty else { return }
        let encodedGo = goURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? goURL
        let candidates = [
            "https://passport.biligame.com/x/passport-login/web/crossDomain?ticket=\(ticket)&gourl=\(encodedGo)",
            "https://passport.bilibili.com/x/passport-login/web/crossDomain?ticket=\(ticket)&gourl=\(encodedGo)",
            "https://passport.biligame.com/crossDomain?ticket=\(ticket)&gourl=\(encodedGo)"
        ]
        for candidate in candidates {
            guard let target = URL(string: candidate) else { continue }
            let request = BiliClient.shared.makeRequest(url: target, referer: "https://passport.bilibili.com/")
            _ = try? await BiliClient.shared.session.data(for: request)
            if BiliClient.shared.cookieValue("SESSDATA") != nil { return }
        }
    }

    private struct QRGenerateData: Decodable {
        let url: String
        let qrcode_key: String
    }

    private struct QRPollData: Decodable {
        let url: String?
        let refresh_token: String?
        let timestamp: Int?
        let code: Int?
        let message: String?
    }

    private static func generateQRCode() async throws -> (url: String, key: String) {
        guard let url = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate?source=main-fe-header") else {
            throw BiliError.invalidURL
        }
        var request = BiliClient.shared.makeRequest(url: url, referer: "https://passport.bilibili.com/")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await BiliClient.shared.session.data(for: request)
        let wrapper = try JSONDecoder().decode(BiliResponse<QRGenerateData>.self, from: data)
        guard let payload = wrapper.data else { throw BiliError.decoding("二维码生成失败") }
        return (payload.url, payload.qrcode_key)
    }

    private static func renderQRCode(_ string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
