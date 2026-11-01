import SwiftUI

struct WatchContentView: View {
    @StateObject private var recorder = WatchRecorder()
    @AppStorage("autoStart") private var autoStart = false
    @State private var didAutoStart = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(recorder.isRecording ? formatTime(recorder.elapsed) : "录音转写")
                    .font(recorder.isRecording ? Font.title2.monospacedDigit().weight(.semibold) : Font.headline)
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)

                Button {
                    recorder.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(.gray.opacity(0.5), lineWidth: 3)
                            .frame(width: 86, height: 86)
                        if recorder.isRecording {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.red)
                                .frame(width: 32, height: 32)
                        } else {
                            Circle()
                                .fill(.red)
                                .frame(width: 70, height: 70)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isRecording ? "停止录音" : "开始录音")

                if recorder.pending > 0 {
                    Label("待传 \(recorder.pending) 条", systemImage: "arrow.up.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !recorder.message.isEmpty {
                    Text(recorder.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Toggle("打开就开始录", isOn: $autoStart)
                    .font(.footnote)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            recorder.refreshPending()
            if autoStart && !didAutoStart && !recorder.isRecording {
                didAutoStart = true
                recorder.start()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vnTransferChanged)) { _ in
            recorder.refreshPending()
        }
    }

    private func formatTime(_ t: Double) -> String {
        let s = Int(t)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
