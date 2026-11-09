import SwiftUI

struct LoginSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = LoginService()

    var body: some View {
        VStack(spacing: 18) {
            Text("扫码登录")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.text1)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)
                if let image = service.qrImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 190, height: 190)
                        .padding(10)
                } else if case .loading = service.phase {
                    ProgressView()
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 70))
                        .foregroundStyle(Color.gray)
                }

                if service.phase == .scanned {
                    overlay("已扫码，请在手机 App 上点击「确认登录」")
                } else if service.phase == .expired {
                    overlay("二维码已失效")
                } else if case .failed(let message) = service.phase {
                    overlay(message)
                }
            }
            .frame(width: 210, height: 210)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))

            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .frame(height: 32)

            HStack(spacing: 12) {
                if service.phase == .expired || isFailed {
                    Button("刷新二维码") { service.start() }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.pink)
                }
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
            }

            Text("打开哔哩哔哩手机客户端，使用扫一扫登录")
                .font(.system(size: 11))
                .foregroundStyle(Palette.text3)
        }
        .padding(28)
        .frame(width: 360)
        .background(Palette.bg)
        .onAppear { service.start() }
        .onDisappear { service.stop() }
        .onChange(of: service.phase) { _, phase in
            if phase == .confirmed {
                Task {
                    await app.refreshUser()
                    app.showToast("登录成功")
                    dismiss()
                }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = service.phase { return true }
        return false
    }

    private var statusText: String {
        switch service.phase {
        case .idle: return "准备中…"
        case .loading: return "正在获取二维码…"
        case .waiting: return "请使用手机哔哩哔哩扫描二维码"
        case .scanned: return "已扫码，请在手机 App 上点击「确认登录」"
        case .confirmed: return "登录成功"
        case .expired: return "二维码已失效，请刷新后重试"
        case .failed(let message): return message
        }
    }

    private func overlay(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 26))
                Text(text)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
