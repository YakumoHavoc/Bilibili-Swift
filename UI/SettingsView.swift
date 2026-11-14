import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "设置", subtitle: "外观、播放与弹幕偏好")
                    .padding(.bottom, 2)

                section("外观") {
                    row("主题") {
                        Picker("", selection: $app.themeMode) {
                            ForEach(ThemeMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    Divider().overlay(Palette.line)
                    row("字体大小") {
                        Picker("", selection: $app.uiFontScale) {
                            ForEach(UIFontScale.options, id: \.self) { scale in
                                Text(UIFontScale.title(for: scale)).tag(scale)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)
                    }
                }

                section("播放") {
                    row("默认清晰度") {
                        Picker("", selection: $app.playQuality) {
                            Text("1080P").tag(80)
                            Text("720P").tag(64)
                            Text("480P").tag(32)
                            Text("360P").tag(16)
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    Divider().overlay(Palette.line)
                    NoteRow(text: "清晰度受账号权限与视频源限制，未登录时最高 720P。")
                }

                section("弹幕") {
                    row("显示弹幕") {
                        Toggle("", isOn: $app.danmakuEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Divider().overlay(Palette.line)
                    row("弹幕不透明度") {
                        Slider(value: $app.danmakuOpacity, in: 0.2...1)
                            .frame(width: 200)
                        Text("\(Int(app.danmakuOpacity * 100))%")
                            .font(.ui(11))
                            .foregroundStyle(Palette.text3)
                            .frame(width: 38, alignment: .trailing)
                    }
                    Divider().overlay(Palette.line)
                    row("弹幕字号") {
                        Slider(value: $app.danmakuFontSize, in: 12...30, step: 1)
                            .frame(width: 200)
                        Text("\(Int(app.danmakuFontSize))")
                            .font(.ui(11))
                            .foregroundStyle(Palette.text3)
                            .frame(width: 38, alignment: .trailing)
                    }
                }

                section("缓存") {
                    row("图片缓存") {
                        Button("清除缓存") {
                            Task {
                                await ImageLoader.shared.clear()
                                app.showToast("图片缓存已清除")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    Divider().overlay(Palette.line)
                    row("登录状态") {
                        if app.user != nil {
                            Button("退出登录") { app.logout() }
                                .buttonStyle(.bordered)
                        } else {
                            Button("扫码登录") { app.showLogin = true }
                                .buttonStyle(.borderedProminent)
                                .tint(Palette.pink)
                        }
                    }
                }

                section("关于") {
                    row("版本") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .font(.ui(12))
                            .foregroundStyle(Palette.text3)
                    }
                    Divider().overlay(Palette.line)
                    NoteRow(text: "哔哩哔哩原生 macOS 客户端，使用 SwiftUI + AVFoundation 构建，数据来自哔哩哔哩公开接口。")
                }
            }
            .padding(Metrics.contentPadding)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bg)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.ui(13, weight: .semibold))
                .foregroundStyle(Palette.text2)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(Palette.bgThin)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func row<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.ui(13))
                .foregroundStyle(Palette.text1)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }
}

struct NoteRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.ui(11))
            .foregroundStyle(Palette.text3)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }
}
