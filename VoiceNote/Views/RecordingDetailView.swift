import SwiftUI
import SwiftData
import UIKit

struct RecordingDetailView: View {
    @Bindable var rec: Recording
    @ObservedObject private var processor = Processor.shared
    @StateObject private var player = AudioPlayerModel()
    @State private var tab = 0
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var copied = false

    private var isBusy: Bool { processor.busy.contains(rec.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                PlayerView(player: player)
                statusView
                actions
                Picker("内容", selection: $tab) {
                    Text("整理").tag(0)
                    Text("原文").tag(1)
                }
                .pickerStyle(.segmented)
                content
            }
            .padding()
        }
        .navigationTitle("录音详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { UIPasteboard.general.string = exportText; copied = true } label: {
                        Label("复制全部文字", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: exportText) {
                        Label("分享文字", systemImage: "text.quote")
                    }
                    ShareLink(item: rec.fileURL) {
                        Label("分享录音文件", systemImage: "waveform")
                    }
                    Button {
                        newTitle = rec.title
                        renaming = true
                    } label: {
                        Label("改标题", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("改标题", isPresented: $renaming) {
            TextField("标题", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let t = newTitle.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { rec.title = t }
            }
        }
        .alert("已复制", isPresented: $copied) {
            Button("好", role: .cancel) {}
        }
        .onAppear {
            player.load(rec.fileURL)
            if rec.summary.isEmpty { tab = 1 }
        }
        .onDisappear { player.stop() }
        .onChange(of: rec.summary) { _, newValue in
            if !newValue.isEmpty { tab = 0 }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rec.title)
                .font(.title2.bold())
                .onTapGesture {
                    newTitle = rec.title
                    renaming = true
                }
            HStack(spacing: 6) {
                Image(systemName: rec.source.icon)
                Text(rec.createdAt, format: .dateTime.year().month().day().hour().minute())
                Text("·")
                Text(formatDuration(rec.duration))
                if !rec.engineUsed.isEmpty {
                    Text("·")
                    Text(rec.engineUsed)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusView: some View {
        if rec.status == .transcribing {
            let p = processor.progress[rec.id] ?? 0
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p)
                Text("正在转写 \(Int(p * 100))%，可以先去做别的")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if rec.status == .organizing {
            HStack(spacing: 8) {
                ProgressView()
                Text("AI 正在整理…").font(.footnote).foregroundStyle(.secondary)
            }
        }
        if !rec.errorMessage.isEmpty {
            Text(rec.errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(ASREngine.allCases) { engine in
                    Button(engine.label) {
                        processor.requestTranscribe(rec, engine: engine)
                    }
                }
            } label: {
                Label(rec.transcript.isEmpty ? "转写" : "重新转写", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                processor.requestOrganize(rec)
            } label: {
                Label(rec.summary.isEmpty ? "AI 整理" : "重新整理", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!rec.hasSpeech)
        }
        .disabled(isBusy)
    }

    @ViewBuilder private var content: some View {
        if tab == 0 {
            if rec.summary.isEmpty {
                Text(rec.hasSpeech ? "还没整理，点上面的「AI 整理」。" : "先转写，再整理。")
                    .foregroundStyle(.secondary)
            } else {
                MarkdownLite(text: rec.summary)
            }
        } else {
            if rec.transcript.isEmpty {
                Text("还没转写，点上面的「转写」。")
                    .foregroundStyle(.secondary)
            } else {
                Text(rec.transcript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var exportText: String {
        var parts: [String] = []
        if !rec.summary.isEmpty {
            parts.append(rec.summary)
        } else {
            parts.append("# \(rec.title)")
        }
        if rec.hasSpeech {
            parts.append("## 转写原文\n\(rec.transcript)")
        }
        return parts.joined(separator: "\n\n")
    }
}

struct PlayerView: View {
    @ObservedObject var player: AudioPlayerModel

    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(
                get: { player.current },
                set: { player.seek($0) }
            ), in: 0...max(player.duration, 0.1))
            HStack {
                Text(formatDuration(player.current))
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                }
                .padding(.horizontal, 16)
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                Spacer()
                Text(formatDuration(player.duration))
            }
            .font(.footnote.monospacedDigit())
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 简单的 Markdown 显示：标题、列表、待办、加粗
struct MarkdownLite: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("### ") {
            Text(inline(String(line.dropFirst(4)))).font(.subheadline.bold()).padding(.top, 4)
        } else if line.hasPrefix("## ") {
            Text(inline(String(line.dropFirst(3)))).font(.headline).padding(.top, 10)
        } else if line.hasPrefix("# ") {
            Text(inline(String(line.dropFirst(2)))).font(.title3.bold())
        } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: line.hasPrefix("- [ ] ") ? "square" : "checkmark.square")
                Text(inline(String(line.dropFirst(6))))
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(String(line.dropFirst(2))))
            }
        } else if line.isEmpty {
            Color.clear.frame(height: 2)
        } else {
            Text(inline(line))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}
