import SwiftUI
import SwiftData
import UIKit

struct RecordingDetailView: View {
    @Bindable var rec: Recording
    @ObservedObject private var processor = Processor.shared
    @StateObject private var player = AudioPlayerModel()
    @Namespace private var tabNS

    @State private var tab = 0
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var toast: String?
    @State private var editing: TranscriptSegment?
    @State private var editText = ""
    @AppStorage("playSingleSentence") private var singleSentence = true
    @State private var shareItem: ShareItem?
    @State private var exporting = false
    @State private var exportError: String?

    // 缓存：播放时每 0.1 秒刷新界面，不要每次都重新解析
    @State private var segs: [TranscriptSegment] = []
    @State private var lines: [OrganizedLine] = []
    @State private var waveform: [Float] = []
    @State private var showFullPlayer = false

    private var isBusy: Bool { processor.busy.contains(rec.id) }

    private var activeLineID: Int? {
        guard player.isPlaying || player.current > 0 else { return nil }
        let t = player.current
        return lines
            .filter { l in
                guard let s = l.start, let e = l.end else { return false }
                return t >= s && t < e
            }
            .max(by: { ($0.start ?? 0) < ($1.start ?? 0) })?.id
    }

    private var activeSegmentID: UUID? {
        guard player.isPlaying || player.current > 0 else { return nil }
        return segs.first(where: { $0.contains(player.current) })?.id
    }

    var body: some View {
        TabView(selection: $tab) {
            page(index: 0) { organizedContent }
                .tag(0)
            page(index: 1) { transcriptContent }
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) {
            MiniPlayer(player: player, singleSentence: $singleSentence, showFull: $showFullPlayer)
                .padding(.trailing, 18)
                .padding(.bottom, 10)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu }
        .alert("改标题", isPresented: $renaming) {
            TextField("标题", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let t = newTitle.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { rec.title = t }
            }
        }
        .sheet(item: $editing) { seg in editSheet(seg) }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.items)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showFullPlayer) {
            PlayerPanel(player: player, waveform: waveform, singleSentence: $singleSentence)
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .presentationDetents([.height(230)])
                .presentationDragIndicator(.visible)
                .presentationBackground(.thinMaterial)
        }
        .overlay {
            if exporting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在剪切录音…").font(.subheadline)
                }
                .padding(24)
                .glassBackground(cornerRadius: 20)
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassBackground(cornerRadius: 22)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 4)
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
        .onAppear {
            player.load(rec.fileURL)
            refresh()
            if rec.summary.isEmpty { tab = 1 }
        }
        .task(id: rec.fileName) {
            if let c = WaveformLoader.cached(rec.fileURL) {
                waveform = c
            } else {
                let w = await WaveformLoader.load(url: rec.fileURL, count: 72)
                WaveformLoader.store(rec.fileURL, w)
                waveform = w
            }
        }
        .onDisappear { player.stop() }
        .onChange(of: rec.summary) { _, newValue in
            refresh()
            if !newValue.isEmpty { withAnimation(.snappy) { tab = 0 } }
        }
        .onChange(of: rec.segmentsData) { _, _ in refresh() }
    }

    /// 每一页：顶部信息 + 吸顶的切换条 + 内容。左右滑动切换整理/原文
    private func page<Content: View>(index: Int, @ViewBuilder content: () -> Content) -> some View {
        let body = content()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        statusCard
                        actions
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                    Section {
                        body
                            .padding(.horizontal, 16)
                            .padding(.bottom, 110)
                    } header: {
                        tabSwitcher
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color(.systemGroupedBackground))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: activeSegmentID) { _, id in
                guard index == 1, let id, player.isPlaying, tab == 1 else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: activeLineID) { _, id in
                guard index == 0, let id, player.isPlaying, tab == 0 else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("line-\(id)", anchor: .center) }
            }
        }
    }

    private func refresh() {
        segs = rec.segments
        lines = OrganizedParser.parse(rec.summary, segments: segs)
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(duration: 0.35)) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showToast("已复制")
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rec.title)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture {
                    newTitle = rec.title
                    renaming = true
                }
            Text(rec.createdAt, format: .dateTime.year().month().day().weekday().hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Chip(icon: rec.source.icon, text: rec.source.label)
                Chip(icon: "clock", text: formatDuration(rec.duration))
                if !rec.engineUsed.isEmpty {
                    Chip(icon: "waveform", text: rec.engineUsed)
                }
            }
        }
    }

    @ViewBuilder private var statusCard: some View {
        if rec.status == .transcribing {
            let p = processor.progress[rec.id] ?? 0
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("正在转写", systemImage: "waveform.badge.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(p * 100))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: p).tint(Theme.accent)
                Text("可以先去做别的，转完会自动保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .cardBackground()
        } else if rec.status == .organizing {
            HStack(spacing: 12) {
                ProgressView().tint(Theme.ai)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 正在整理").font(.subheadline.weight(.semibold))
                    Text("长录音要一两分钟").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .cardBackground()
        }
        if !rec.errorMessage.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(rec.errorMessage)
                    .font(.footnote)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble.fill")
                    Text(rec.transcript.isEmpty ? "转写" : "重新转写")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.systemBackground))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Button {
                processor.requestOrganize(rec)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(rec.summary.isEmpty ? "AI 整理" : "重新整理")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Theme.aiGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(rec.hasSpeech ? 1 : 0.4)
            }
            .disabled(!rec.hasSpeech)
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach([0, 1], id: \.self) { i in
                Button {
                    withAnimation(.snappy(duration: 0.3)) { tab = i }
                } label: {
                    Label(i == 0 ? "整理" : "原文", systemImage: i == 0 ? "sparkles" : "text.alignleft")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tab == i ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if tab == i {
                                Capsule()
                                    .fill(Color(.systemBackground))
                                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "tab", in: tabNS)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }

    @ViewBuilder private var organizedContent: some View {
        if rec.summary.isEmpty {
            EmptyHint(icon: "sparkles",
                      title: "还没整理",
                      text: rec.hasSpeech ? "点上面的「AI 整理」，生成摘要、要点和待办\n往左滑可以看原文" : "先转写，再让 AI 整理")
        } else {
            organizedView
        }
    }

    @ViewBuilder private var transcriptContent: some View {
        if rec.transcript.isEmpty {
            EmptyHint(icon: "text.bubble", title: "还没转写", text: "点上面的「转写」，选本机或阿里云")
        } else if !segs.isEmpty {
            transcriptView
        } else {
            Text(rec.transcript)
                .lineSpacing(5)
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
        }
    }

    // MARK: 整理

    private var organizedView: some View {
        let sections = OrgSection.build(from: lines)
        let activeID = activeLineID
        let hasTime = lines.contains { $0.hasTime }
        return VStack(alignment: .leading, spacing: 16) {
            if hasTime {
                TipLine(text: "点段落播放 · 长按复制或分享录音 · 左滑看原文")
            } else if !segs.isEmpty {
                TipLine(text: "点「重新整理」后，每一段都能点着播放")
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 12) {
                    if !section.title.isEmpty {
                        Label(section.title, systemImage: section.icon)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Theme.ai)
                            .textCase(nil)
                    }
                    ForEach(section.lines) { line in
                        OrgLineView(line: line, active: line.id == activeID)
                            .id("line-\(line.id)")
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let s = line.start, let e = line.end {
                                    player.play(from: s, until: singleSentence ? e : nil)
                                }
                            }
                            .contextMenu { lineMenu(line) }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
            }
        }
    }

    @ViewBuilder private func lineMenu(_ line: OrganizedLine) -> some View {
        let text = OrgLineView.plain(line.text)
        Button { copy(text) } label: { Label("复制这段", systemImage: "doc.on.doc") }
        if let s = line.start, let e = line.end {
            Button { player.play(from: s, until: e) } label: { Label("只播这一段", systemImage: "play") }
            Button { player.play(from: s, until: nil) } label: { Label("从这里往下播", systemImage: "play.square.stack") }
            Button { shareClip(start: s, end: e) } label: { Label("分享这段录音", systemImage: "square.and.arrow.up") }
        }
    }

    // MARK: 原文

    private var transcriptView: some View {
        let activeID = activeSegmentID
        return VStack(alignment: .leading, spacing: 4) {
            TipLine(text: "点一句播放 · 长按复制、改字或分享 · 右滑回整理")
                .padding(.bottom, 8)
            ForEach(segs) { seg in
                let active = seg.id == activeID
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(formatDuration(seg.start))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(active ? Theme.accent : Color.secondary)
                        .frame(width: 42, alignment: .leading)
                    Text(seg.text)
                        .lineSpacing(4)
                        .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(active ? Theme.accent.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
                .id(seg.id)
                .onTapGesture {
                    player.play(from: seg.start, until: singleSentence ? seg.end : nil)
                }
                .contextMenu {
                    Button { copy(seg.text) } label: { Label("复制这句", systemImage: "doc.on.doc") }
                    Button { player.play(from: seg.start, until: seg.end) } label: { Label("只播这一句", systemImage: "play") }
                    Button { player.play(from: seg.start, until: nil) } label: { Label("从这里往下播", systemImage: "play.square.stack") }
                    Button {
                        editText = seg.text
                        editing = seg
                    } label: { Label("改字", systemImage: "pencil") }
                    Button { shareClip(start: seg.start, end: seg.end) } label: {
                        Label("分享这句录音", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .padding(8)
        .cardBackground()
    }

    private func editSheet(_ seg: TranscriptSegment) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    player.play(from: seg.start, until: seg.end)
                } label: {
                    Label("听这句 · \(formatDuration(seg.start))", systemImage: "play.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                TextEditor(text: $editText)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("清空后保存会删掉这一句")
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
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 菜单 / 分享

    @ToolbarContentBuilder private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { copy(exportText) } label: { Label("复制全部文字", systemImage: "doc.on.doc") }
                ShareLink(item: exportText) { Label("分享文字", systemImage: "text.quote") }
                ShareLink(item: rec.fileURL) { Label("分享整段录音", systemImage: "waveform") }
                Divider()
                Button {
                    newTitle = rec.title
                    renaming = true
                } label: { Label("改标题", systemImage: "pencil") }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    private func shareClip(start: Double, end: Double) {
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

// MARK: - 播放器

/// 右下角悬浮的小圆播放键：点按播放/暂停，长按更多控制
struct MiniPlayer: View {
    @ObservedObject var player: AudioPlayerModel
    @Binding var singleSentence: Bool
    @Binding var showFull: Bool

    private var progress: Double {
        player.duration > 0 ? min(1, player.current / player.duration) : 0
    }

    var body: some View {
        HStack(spacing: 10) {
            if player.isPlaying || player.current > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(formatDuration(player.current))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                    Text(player.rate == 1 ? formatDuration(player.duration) : String(format: "%g×", player.rate))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassBackground(cornerRadius: 18)
                .onTapGesture { showFull = true }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(x: player.isPlaying ? 0 : 1.5)
                    .frame(width: 48, height: 48)
                    .background(Theme.recordGradient, in: Circle())
            }
            .frame(width: 58, height: 58)
            .padding(4)
            .glassBackground(cornerRadius: 33)
            .shadow(color: Theme.accent.opacity(0.25), radius: 12, y: 5)
            .contentShape(Circle())
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                player.toggle()
            }
            .contextMenu {
                Button { player.skip(-15) } label: { Label("后退 15 秒", systemImage: "gobackward.15") }
                Button { player.skip(15) } label: { Label("前进 15 秒", systemImage: "goforward.15") }
                Menu {
                    ForEach(AudioPlayerModel.rates, id: \.self) { r in
                        Button {
                            player.setRate(r)
                        } label: {
                            if r == player.rate {
                                Label(String(format: "%g×", r), systemImage: "checkmark")
                            } else {
                                Text(String(format: "%g×", r))
                            }
                        }
                    }
                } label: {
                    Label("倍速 \(String(format: "%g×", player.rate))", systemImage: "speedometer")
                }
                Toggle(isOn: $singleSentence) {
                    Label("点一句只播一句", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Divider()
                Button { showFull = true } label: { Label("展开播放器", systemImage: "waveform") }
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
        }
        .animation(.spring(duration: 0.35), value: player.isPlaying || player.current > 0)
    }
}


struct PlayerPanel: View {
    @ObservedObject var player: AudioPlayerModel
    let waveform: [Float]
    @Binding var singleSentence: Bool

    private var progress: Double {
        player.duration > 0 ? player.current / player.duration : 0
    }

    var body: some View {
        VStack(spacing: 10) {
            WaveformScrubber(samples: waveform, progress: progress) { f in
                player.seek(f * player.duration)
            }
            .frame(height: 38)

            HStack {
                Text(formatDuration(player.current))
                Spacer()
                Text("-" + formatDuration(max(0, player.duration - player.current)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack {
                Button { player.cycleRate() } label: {
                    Text(String(format: "%g×", player.rate))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .frame(width: 52, height: 30)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                Spacer()
                Button { player.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title3)
                }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Theme.recordGradient, in: Circle())
                        .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)
                }
                .padding(.horizontal, 20)
                Button { player.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title3)
                }
                Spacer()
                Button { singleSentence.toggle() } label: {
                    Text("单句")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(singleSentence ? Color.white : Color.primary)
                        .frame(width: 52, height: 30)
                        .background(singleSentence ? Theme.accent : Color(.tertiarySystemFill), in: Capsule())
                }
                .accessibilityLabel(singleSentence ? "单句播放已开" : "单句播放已关")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .glassBackground(cornerRadius: 30)
    }
}

// MARK: - 整理内容的分节和每一行

struct OrgSection: Identifiable {
    let id: Int
    let title: String
    var lines: [OrganizedLine]

    var icon: String {
        if title.contains("摘要") { return "text.quote" }
        if title.contains("要点") { return "list.bullet" }
        if title.contains("待办") { return "checklist" }
        if title.contains("正文") { return "text.alignleft" }
        return "doc.text"
    }

    static func build(from lines: [OrganizedLine]) -> [OrgSection] {
        var out: [OrgSection] = []
        var current = OrgSection(id: -1, title: "", lines: [])
        for line in lines {
            let t = line.text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { continue } // 标题已经显示在顶部
            if t.hasPrefix("## ") || t.hasPrefix("### ") {
                if !current.lines.isEmpty || !current.title.isEmpty { out.append(current) }
                let title = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                current = OrgSection(id: line.id, title: title, lines: [])
                continue
            }
            if t.isEmpty { continue }
            current.lines.append(line)
        }
        if !current.lines.isEmpty || !current.title.isEmpty { out.append(current) }
        return out.filter { !$0.lines.isEmpty }
    }
}

struct OrgLineView: View {
    let line: OrganizedLine
    let active: Bool

    private static let speakerFirst: Set<Character> = ["甲", "乙", "丙", "丁", "戊", "说"]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            if let s = line.start, line.hasTime {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 7))
                    Text(formatDuration(s))
                }
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(active ? Color.white : Theme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(active ? Theme.accent : Theme.accent.opacity(0.12), in: Capsule())
                .padding(.top, 2)
            }
        }
        .padding(.vertical, line.hasTime ? 6 : 0)
        .padding(.horizontal, line.hasTime ? 8 : 0)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? Theme.accent.opacity(0.10) : Color.clear)
        )
        .padding(.horizontal, line.hasTime ? -8 : 0)
    }

    @ViewBuilder private var content: some View {
        let t = line.text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- [ ] ") || t.hasPrefix("- [x] ") || t.hasPrefix("- [X] ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: t.hasPrefix("- [ ] ") ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(Theme.ai)
                Text(Self.inline(String(t.dropFirst(6)))).lineSpacing(4)
            }
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(Theme.ai).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
                Text(Self.inline(String(t.dropFirst(2)))).lineSpacing(4)
            }
        } else if let sp = Self.speaker(t) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sp.name)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.speakerColor(sp.name))
                Text(Self.inline(sp.body)).lineSpacing(5)
            }
        } else {
            Text(Self.inline(t)).lineSpacing(5)
        }
    }

    static func speaker(_ t: String) -> (name: String, body: String)? {
        guard let first = t.first, speakerFirst.contains(first) else { return nil }
        guard let r = t.range(of: "：") ?? t.range(of: ":") else { return nil }
        let name = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 10 else { return nil }
        return (name, String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }

    static func plain(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        for p in ["### ", "## ", "# ", "- [ ] ", "- [x] ", "- [X] ", "- ", "* "] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count))
            break
        }
        return t.replacingOccurrences(of: "**", with: "")
    }
}

struct TipLine: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "hand.tap")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct EmptyHint: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .cardBackground()
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
