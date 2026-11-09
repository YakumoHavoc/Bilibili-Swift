import SwiftUI
import AppKit

struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                PageHeader(title: "下载", subtitle: subtitle) {
                    HStack(spacing: 8) {
                        if manager.tasks.contains(where: { $0.state == .finished || $0.state == .failed }) {
                            PlainIconButton(systemName: "trash", action: {
                                manager.clearFinished()
                            }, help: "清除已完成")
                        }
                        PlainIconButton(systemName: "folder", action: {
                            manager.revealDownloadsFolder()
                        }, help: "打开下载目录")
                    }
                }
                .padding(.bottom, 4)

                if manager.tasks.isEmpty {
                    emptyState
                } else {
                    ForEach(manager.tasks) { task in
                        DownloadRow(task: task,
                                    onCancel: { manager.cancel(task.id) },
                                    onReveal: { manager.reveal(task.id) })
                    }
                }
            }
            .padding(Metrics.contentPadding)
        }
        .background(Palette.bg)
        .task {
            manager.loadDownloads()
        }
    }

    private var subtitle: String {
        if manager.tasks.isEmpty {
            return "下载的视频会保存在「下载」文件夹的哔哩哔哩目录"
        }
        return "共 \(manager.tasks.count) 个视频"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 34))
                .foregroundStyle(Palette.text3)
            Text("暂无下载任务")
                .font(.system(size: 13))
                .foregroundStyle(Palette.text2)
            Text("在播放器控制栏点击下载按钮即可保存视频")
                .font(.system(size: 11))
                .foregroundStyle(Palette.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

private struct DownloadRow: View {
    let task: DownloadTaskItem
    let onCancel: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 38, height: 38)
                .background(iconColor.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text1)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(task.qualityTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.blue.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)

                    if task.state == .finished, task.danmakuCount > 0 {
                        Text("\(task.danmakuCount) 条弹幕")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.text3)
                    }
                }

                if task.isActive {
                    ProgressView(value: task.progress)
                        .progressViewStyle(.linear)
                        .tint(Palette.pink)
                        .frame(maxWidth: 360)
                } else if task.state == .finished, let folder = task.fileURL?.deletingLastPathComponent() {
                    Text(folder.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if task.isActive {
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Palette.bgThin)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else if task.state == .finished {
                Button(action: onReveal) {
                    Text("在 Finder 中显示")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.pink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Palette.pink.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgThin)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusText: String {
        if task.state == .failed {
            return task.error ?? "下载失败"
        }
        return task.stateText
    }

    private var statusColor: Color {
        switch task.state {
        case .failed: return Palette.pink
        case .finished: return Palette.text3
        default: return Palette.text2
        }
    }

    private var icon: String {
        switch task.state {
        case .preparing: return "clock"
        case .downloading: return "arrow.down"
        case .merging: return "square.stack.3d.up"
        case .finished: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private var iconColor: Color {
        switch task.state {
        case .failed: return Palette.pink
        default: return Palette.blue
        }
    }
}
