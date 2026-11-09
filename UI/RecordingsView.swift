import SwiftUI
import AppKit

/// 直播录制列表：与视频下载分开展示，录制文件保存在「下载/哔哩哔哩/直播录制」。
struct RecordingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var recorder = LiveRecorder.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                PageHeader(title: "直播录制", subtitle: subtitle) {
                    HStack(spacing: 8) {
                        PlainIconButton(systemName: "arrow.clockwise", action: {
                            recorder.loadRecordings()
                        }, help: "刷新录制列表")
                        PlainIconButton(systemName: "folder", action: {
                            recorder.revealDirectory()
                        }, help: "打开录制目录")
                    }
                }
                .padding(.bottom, 4)

                if recorder.recordingCount > 0 {
                    liveRows
                }

                if recorder.recordings.isEmpty {
                    if recorder.recordingCount == 0 {
                        emptyState
                    }
                } else {
                    ForEach(recorder.recordings) { recording in
                        RecordingRow(recording: recording,
                                     onPlay: {
                                         PlayerWindowController.shared.openRecording(recording, app: app)
                                     },
                                     onReveal: {
                                         NSWorkspace.shared.activateFileViewerSelecting([recording.folderURL])
                                     },
                                     onDelete: {
                                         recorder.delete(recording)
                                     })
                    }
                }
            }
            .padding(Metrics.contentPadding)
        }
        .background(Palette.bg)
        .task {
            recorder.loadRecordings()
        }
    }

    private var subtitle: String {
        if recorder.recordings.isEmpty {
            return "在直播播放器中点击录制按钮，录制完成后会显示在这里"
        }
        return "共 \(recorder.recordings.count) 个录制 · 保存在「下载/哔哩哔哩/直播录制」"
    }

    private var liveRows: some View {
        ForEach(recorder.activeSessions) { session in
            HStack(spacing: 14) {
                Image(systemName: "record.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Palette.pink)
                    .frame(width: 38, height: 38)
                    .background(Palette.pink.opacity(0.1))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(session.title.isEmpty ? "正在录制" : session.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text1)
                        .lineLimit(1)
                    Text("正在录制 · 已录制 \(Fmt.duration(Int(recorder.elapsed(for: session.id))))")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                }

                Spacer(minLength: 12)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.pink.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "record.circle")
                .font(.system(size: 34))
                .foregroundStyle(Palette.text3)
            Text("暂无直播录制")
                .font(.system(size: 13))
                .foregroundStyle(Palette.text2)
            Text("在直播播放器控制栏点击录制按钮即可开始录制")
                .font(.system(size: 11))
                .foregroundStyle(Palette.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

private struct RecordingRow: View {
    let recording: LiveRecording
    let onPlay: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "record.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.pink)
                .frame(width: 38, height: 38)
                .background(Palette.pink.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(recording.title.isEmpty ? "直播录制" : recording.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text1)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if recording.duration > 0 {
                        Text(Fmt.duration(Int(recording.duration)))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.pink)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.pink.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text(Fmt.relativeDate(Int(recording.createdAt.timeIntervalSince1970)))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)

                    Text("\(recording.danmakuCount) 条弹幕")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                }
            }

            Spacer(minLength: 12)

            Button(action: onPlay) {
                Text("回放")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.pink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Palette.pink.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            PlainIconButton(systemName: "folder", action: onReveal, help: "在 Finder 中显示")
            PlainIconButton(systemName: "trash", action: onDelete, help: "删除录制")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgThin)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
