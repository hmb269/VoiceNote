import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @StateObject private var recorder = PhoneRecorder()
    @ObservedObject private var processor = Processor.shared
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var alertText: String?
    @State private var search = ""

    private var filtered: [Recording] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recordings }
        return recordings.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.transcript.localizedCaseInsensitiveContains(q)
                || $0.summary.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if recordings.isEmpty {
                    ContentUnavailableView {
                        Label("还没有录音", systemImage: "waveform")
                    } description: {
                        Text("点下面的红色按钮开始录；右上角可以导入音频文件；手表上录的会自动同步过来。")
                    }
                } else {
                    List {
                        ForEach(filtered) { rec in
                            NavigationLink(value: rec) {
                                RecordingRow(rec: rec)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.plain)
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
            .safeAreaInset(edge: .bottom) {
                RecordBar(recorder: recorder) { alertText = $0 }
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
    }

    private func delete(at offsets: IndexSet) {
        let items = offsets.map { filtered[$0] }
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
        VStack(alignment: .leading, spacing: 4) {
            Text(rec.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Image(systemName: rec.source.icon)
                Text(rec.createdAt, format: .dateTime.month().day().hour().minute())
                Text("·")
                Text(formatDuration(rec.duration))
                Spacer()
                statusBadge
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !rec.summary.isEmpty || rec.hasSpeech {
                Text(previewText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var previewText: String {
        let src = rec.summary.isEmpty ? rec.transcript : rec.summary
        return src.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: " ")
    }

    @ViewBuilder private var statusBadge: some View {
        switch rec.status {
        case .transcribing:
            let p = processor.progress[rec.id] ?? 0
            Text("转写中 \(Int(p * 100))%").foregroundStyle(.orange)
        case .organizing:
            Text("整理中…").foregroundStyle(.purple)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .done:
            if !rec.summary.isEmpty {
                Image(systemName: "sparkles").foregroundStyle(.purple)
            } else {
                Image(systemName: "text.alignleft")
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
        VStack(spacing: 10) {
            if recorder.isRecording {
                Text(formatDuration(recorder.elapsed))
                    .font(.title2.monospacedDigit().weight(.semibold))
                LevelBar(level: recorder.level)
                    .frame(height: 6)
                    .padding(.horizontal, 60)
            }
            Button(action: toggle) {
                ZStack {
                    Circle()
                        .strokeBorder(.secondary.opacity(0.4), lineWidth: 3)
                        .frame(width: 76, height: 76)
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.red)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 62, height: 62)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording ? "停止录音" : "开始录音")
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func toggle() {
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

struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.2))
                Capsule().fill(.red)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}
