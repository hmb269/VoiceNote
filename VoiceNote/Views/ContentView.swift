import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @StateObject private var recorder = PhoneRecorder()
    @ObservedObject private var processor = Processor.shared
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var alertText: String?
    @State private var search = ""
    @State private var path: [Recording] = []

    private var filtered: [Recording] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recordings }
        return recordings.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.transcript.localizedCaseInsensitiveContains(q)
                || $0.summary.localizedCaseInsensitiveContains(q)
        }
    }

    private var grouped: [(key: Date, items: [Recording])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.createdAt) }
        return dict.keys.sorted(by: >).map { (key: $0, items: dict[$0] ?? []) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if recordings.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(grouped, id: \.key) { group in
                            Section {
                                ForEach(group.items) { rec in
                                    NavigationLink(value: rec) {
                                        RecordingRow(rec: rec)
                                    }
                                    .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                                }
                                .onDelete { offsets in
                                    delete(offsets.map { group.items[$0] })
                                }
                            } header: {
                                Text(dayTitle(group.key))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                            }
                        }
                        Color.clear.frame(height: 90)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.insetGrouped)
                    .listSectionSpacing(14)
                    .searchable(text: $search, prompt: "搜索标题和文字")
                }
            }
            .navigationTitle("录音转写")
            .navigationDestination(for: Recording.self) { rec in
                RecordingDetailView(rec: rec)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel("导入音频")
                }
            }
            .overlay(alignment: .bottom) {
                RecordBar(recorder: recorder) { alertText = $0 }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.audio],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    urls.forEach { processor.importFile($0) }
                case .failure(let error):
                    alertText = error.localizedDescription
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onChange(of: processor.lastError) { _, newValue in
                if let newValue {
                    alertText = newValue
                    processor.lastError = nil
                }
            }
            .alert("出错了", isPresented: Binding(
                get: { alertText != nil },
                set: { if !$0 { alertText = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertText ?? "")
            }
        }
        .tint(Theme.accent)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: 120, height: 120)
                Image(systemName: "waveform")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(Theme.recordGradient)
            }
            Text("开始你的第一段录音")
                .font(.system(.title3, design: .rounded).weight(.bold))
            VStack(spacing: 6) {
                Label("点下方按钮录音，锁屏也能继续", systemImage: "mic")
                Label("手表上录的会自动同步过来", systemImage: "applewatch")
                Label("右上角导入，或从语音备忘录分享", systemImage: "square.and.arrow.down")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 120)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日 EEEE" : "yyyy年M月d日"
        return f.string(from: d)
    }

    private func delete(_ items: [Recording]) {
        for rec in items {
            try? FileManager.default.removeItem(at: rec.fileURL)
            context.delete(rec)
        }
        try? context.save()
    }
}

struct RecordingRow: View {
    let rec: Recording
    @ObservedObject private var processor = Processor.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconTint.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: rec.source.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(rec.title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(rec.createdAt, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !previewText.isEmpty {
                    Text(previewText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(formatDuration(rec.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    statusBadge
                }
            }
        }
    }

    private var iconTint: Color {
        switch rec.source {
        case .phone: return Theme.accent
        case .watch: return Color(red: 0.20, green: 0.55, blue: 0.95)
        case .imported: return Color(red: 0.95, green: 0.60, blue: 0.15)
        }
    }

    /// 优先显示摘要，没有就显示原文开头
    private var previewText: String {
        let source: String
        if !rec.summary.isEmpty {
            let clean = OrganizedParser.stripMarkers(rec.summary)
            let lines = clean.components(separatedBy: "\n")
            if let i = lines.firstIndex(where: { $0.contains("摘要") && $0.hasPrefix("#") }) {
                source = lines[(i + 1)...].prefix { !$0.hasPrefix("#") }.joined(separator: " ")
            } else {
                source = clean
            }
        } else if rec.hasSpeech {
            source = rec.transcript
        } else {
            return ""
        }
        return source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: " ")
    }

    @ViewBuilder private var statusBadge: some View {
        switch rec.status {
        case .transcribing:
            let p = processor.progress[rec.id] ?? 0
            Chip(icon: "waveform", text: "转写中 \(Int(p * 100))%", tint: .orange)
        case .organizing:
            Chip(icon: "sparkles", text: "整理中", tint: Theme.ai)
        case .failed:
            Chip(icon: "exclamationmark.triangle.fill", text: "失败", tint: .red)
        case .done:
            if !rec.summary.isEmpty {
                Chip(icon: "sparkles", text: "已整理", tint: Theme.ai)
            } else if rec.hasSpeech {
                Chip(icon: "text.alignleft", text: "已转写", tint: .secondary)
            }
        case .idle:
            EmptyView()
        }
    }
}

struct RecordBar: View {
    @ObservedObject var recorder: PhoneRecorder
    var onError: (String) -> Void

    var body: some View {
        Group {
            if recorder.isRecording {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.accent).frame(width: 8, height: 8)
                            Text("录音中").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                        Text(formatDuration(recorder.elapsed))
                            .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                    }
                    LiveLevels(levels: Array(recorder.levels.suffix(22)))
                        .frame(maxWidth: .infinity)
                    Button(action: toggle) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white)
                            .frame(width: 20, height: 20)
                            .frame(width: 56, height: 56)
                            .background(Theme.recordGradient, in: Circle())
                            .shadow(color: Theme.accent.opacity(0.4), radius: 10, y: 4)
                    }
                    .accessibilityLabel("停止录音")
                }
                .padding(.leading, 20)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
                .glassBackground(cornerRadius: 38)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                Button(action: toggle) {
                    HStack(spacing: 10) {
                        Image(systemName: "mic.fill")
                        Text("开始录音")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .frame(height: 56)
                    .background(Theme.recordGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 6)
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: recorder.isRecording)
    }

    private func toggle() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if recorder.isRecording {
            if let r = recorder.stop() {
                Processor.shared.ingest(fileName: r.fileName, source: .phone, createdAt: r.startedAt)
            }
        } else {
            Task {
                do { try await recorder.start() } catch { onError(error.localizedDescription) }
            }
        }
    }
}
