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
    @State private var editing: TranscriptSegment?
    @State private var editText = ""
    @AppStorage("playSingleSentence") private var singleSentence = true
    @State private var shareItem: ShareItem?
    @State private var exporting = false
    @State private var exportError: String?

    private var isBusy: Bool { processor.busy.contains(rec.id) }

    private var segments: [TranscriptSegment] { rec.segments }

    private var organizedLines: [OrganizedLine] {
        OrganizedParser.parse(rec.summary, segments: segments)
    }

    private var currentLineID: Int? { activeLineID(in: organizedLines) }

    private func activeLineID(in lines: [OrganizedLine]) -> Int? {
        guard player.isPlaying || player.current > 0 else { return nil }
        let t = player.current
        // 取开始时间最晚、且包含当前时间的那行
        return lines
            .filter { line in
                guard let s = line.start, let e = line.end else { return false }
                return t >= s && t < e
            }
            .max(by: { ($0.start ?? 0) < ($1.start ?? 0) })?.id
    }

    private var currentSegmentID: UUID? { activeSegmentID(in: segments) }

    private func activeSegmentID(in segs: [TranscriptSegment]) -> UUID? {
        guard player.isPlaying || player.current > 0 else { return nil }
        return segs.first(where: { $0.contains(player.current) })?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
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
        .onChange(of: currentSegmentID) { _, id in
            guard let id, player.isPlaying, tab == 1 else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .onChange(of: currentLineID) { _, id in
            guard let id, player.isPlaying, tab == 0 else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo("line-\(id)", anchor: .center)
            }
        }
        }
        .safeAreaInset(edge: .bottom) {
            PlayerView(player: player)
                .padding(.horizontal)
                .padding(.bottom, 4)
                .background(.bar)
        }
        .sheet(item: $editing) { seg in
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        player.play(from: seg.start, until: seg.end)
                    } label: {
                        Label("听这句 \(formatDuration(seg.start))", systemImage: "play.circle")
                    }
                    TextEditor(text: $editText)
                        .font(.body)
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    Text("清空后保存会删掉这一句。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .navigationTitle("校对这句")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { editing = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            processor.updateSegment(rec, id: seg.id, text: editText)
                            editing = nil
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
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
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.items)
                .presentationDetents([.medium, .large])
        }
        .overlay {
            if exporting {
                ProgressView("正在剪切录音…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
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
                organizedList
            }
        } else {
            if rec.transcript.isEmpty {
                Text("还没转写，点上面的「转写」。")
                    .foregroundStyle(.secondary)
            } else if !segments.isEmpty {
                segmentList
            } else {
                Text(rec.transcript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var segmentList: some View {
        let segs = segments
        let activeID = activeSegmentID(in: segs)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(isOn: $singleSentence) {
                    Text("点一句只播这一句").font(.footnote)
                }
                .toggleStyle(.switch)
            }
            .padding(.bottom, 6)
            Text("点句子播放，长按可以改字")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            ForEach(segs) { seg in
                let active = seg.id == activeID
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(formatDuration(seg.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(active ? Color.accentColor : Color.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(seg.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(active ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .id(seg.id)
                .onTapGesture {
                    player.play(from: seg.start, until: singleSentence ? seg.end : nil)
                }
                .contextMenu {
                    Button {
                        player.play(from: seg.start, until: seg.end)
                    } label: { Label("只播这一句", systemImage: "play") }
                    Button {
                        player.play(from: seg.start, until: nil)
                    } label: { Label("从这里往下播", systemImage: "play.square.stack") }
                    Button {
                        editText = seg.text
                        editing = seg
                    } label: { Label("改字", systemImage: "pencil") }
                    Button {
                        shareClip(start: seg.start, end: seg.end, text: seg.text)
                    } label: { Label("分享这句录音", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }

    private var organizedList: some View {
        let lines = organizedLines
        let activeID = activeLineID(in: lines)
        let hasAnyTime = lines.contains { $0.hasTime }
        return VStack(alignment: .leading, spacing: 6) {
            if hasAnyTime {
                Text("带 ▶︎ 的段落点一下就播放对应录音，长按可以分享这段录音")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            } else if !segments.isEmpty {
                Text("点「重新整理」后，正文和要点就能点击播放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            ForEach(lines) { line in
                let active = line.id == activeID
                MarkdownLine(raw: line.text, playable: line.hasTime)
                    .padding(.vertical, line.hasTime ? 3 : 0)
                    .padding(.horizontal, line.hasTime ? 4 : 0)
                    .background(active ? Color.accentColor.opacity(0.15) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .id("line-\(line.id)")
                    .onTapGesture {
                        if let s = line.start, let e = line.end {
                            player.play(from: s, until: singleSentence ? e : nil)
                        }
                    }
                    .contextMenu {
                        if let s = line.start, let e = line.end {
                            Button {
                                player.play(from: s, until: e)
                            } label: { Label("只播这一段", systemImage: "play") }
                            Button {
                                player.play(from: s, until: nil)
                            } label: { Label("从这里往下播", systemImage: "play.square.stack") }
                            Button {
                                shareClip(start: s, end: e, text: MarkdownLine.plain(line.text))
                            } label: { Label("分享这段录音", systemImage: "square.and.arrow.up") }
                        }
                        Button {
                            UIPasteboard.general.string = MarkdownLine.plain(line.text)
                        } label: { Label("复制这段文字", systemImage: "doc.on.doc") }
                    }
            }
            Toggle(isOn: $singleSentence) {
                Text("点一段只播这一段").font(.footnote)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shareClip(start: Double, end: Double, text: String) {
        guard !exporting else { return }
        exporting = true
        let title = "\(rec.title) \(formatDuration(start).replacingOccurrences(of: ":", with: "′"))"
        let source = rec.fileURL
        Task {
            do {
                let url = try await ClipExporter.export(source: source, start: start, end: end, title: title)
                exporting = false
                shareItem = ShareItem(items: [url])
            } catch {
                exporting = false
                exportError = error.localizedDescription
            }
        }
    }

    private var exportText: String {
        var parts: [String] = []
        if !rec.summary.isEmpty {
            parts.append(OrganizedParser.stripMarkers(rec.summary))
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

/// 一行 Markdown：标题、列表、待办、加粗
struct MarkdownLine: View {
    let raw: String
    var playable = false

    var body: some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            content(line)
            if playable {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func content(_ line: String) -> some View {
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

    /// 去掉 Markdown 符号，用于复制
    static func plain(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        for p in ["### ", "## ", "# ", "- [ ] ", "- [x] ", "- [X] ", "- ", "* "] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count))
            break
        }
        return t.replacingOccurrences(of: "**", with: "")
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
