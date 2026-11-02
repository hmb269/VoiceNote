import SwiftUI
import SwiftData
import UIKit

enum RootTab: Hashable {
    case home, favorites, settings, search
}

struct ContentView: View {
    @StateObject private var recorder = PhoneRecorder()
    @ObservedObject private var processor = Processor.shared
    @AppStorage("appearance") private var appearance = 1
    @State private var tab: RootTab = .home
    @State private var alertText: String?

    private var scheme: ColorScheme? {
        switch appearance {
        case 1: return .dark
        case 2: return .light
        default: return nil
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("录音", systemImage: "waveform", value: RootTab.home) {
                HomeView()
            }
            Tab("收藏", systemImage: "star.fill", value: RootTab.favorites) {
                FavoritesView()
            }
            Tab("设置", systemImage: "gearshape.fill", value: RootTab.settings) {
                SettingsView(showDone: false)
            }
            Tab(value: RootTab.search, role: .search) {
                SearchView()
            }
        }
        .modifier(RecordAccessoryModifier(recorder: recorder) { alertText = $0 })
        .tint(Theme.accent)
        .preferredColorScheme(scheme)
        .overlay(alignment: .top) {
            if let t = processor.toast {
                Label(t, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassBackground(cornerRadius: 22)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: processor.toast)
        .onChange(of: processor.lastError) { _, v in
            if let v {
                alertText = v
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

// MARK: - 首页

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var showPicker = false
    @State private var heroPage = 0
    @State private var toDelete: Recording?

    private var heroItems: [Recording] { Array(recordings.prefix(6)) }
    private var favorites: [Recording] { recordings.filter(\.isFavorite) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if recordings.isEmpty {
                        EmptyHero()
                    } else {
                        hero
                        if !favorites.isEmpty {
                            shelf(title: "收藏", items: favorites)
                        }
                        ForEach(DayGroup.make(recordings)) { g in
                            VStack(alignment: .leading, spacing: 12) {
                                SectionTitle(text: g.title)
                                VStack(spacing: 0) {
                                    ForEach(Array(g.items.enumerated()), id: \.element.id) { i, rec in
                                        NavigationLink(value: rec) {
                                            RecordingRow(rec: rec)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu { RowMenu(rec: rec) { toDelete = rec } }
                                        if i < g.items.count - 1 {
                                            Divider().padding(.leading, 84)
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                                .cardBackground(cornerRadius: 24)
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .scrollIndicators(.hidden)
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel("导入音频")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: Recording.self) { RecordingDetailView(rec: $0) }
            .sheet(isPresented: $showPicker) {
                DocumentPicker { urls in Processor.shared.importFiles(urls) }
                    .ignoresSafeArea()
            }
            .confirmationDialog("删除这条录音？", isPresented: Binding(
                get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }
            ), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let r = toDelete { deleteRecording(r, context: context) }
                }
            } message: {
                Text("录音文件和文字都会删掉，不能恢复")
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $heroPage) {
                ForEach(Array(heroItems.enumerated()), id: \.element.id) { i, rec in
                    NavigationLink(value: rec) {
                        HeroPage(rec: rec)
                    }
                    .buttonStyle(.plain)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if heroItems.count > 1 {
                HStack(spacing: 7) {
                    ForEach(0..<heroItems.count, id: \.self) { i in
                        Capsule()
                            .fill(i == heroPage ? Color.primary : Color.primary.opacity(0.25))
                            .frame(width: i == heroPage ? 18 : 7, height: 7)
                    }
                }
                .animation(.snappy, value: heroPage)
                .padding(.bottom, 4)
            }
        }
        .frame(height: 520)
    }

    private func shelf(title: String, items: [Recording]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { rec in
                        NavigationLink(value: rec) {
                            PosterCard(rec: rec, width: 150)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { RowMenu(rec: rec) { toDelete = rec } }
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct HeroPage: View {
    let rec: Recording

    var body: some View {
        ZStack(alignment: .bottom) {
            CoverArt(seed: rec.id, cornerRadius: 0, barCount: 34)
                .overlay {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: Color(.systemBackground).opacity(0.65), location: 0.72),
                        .init(color: Color(.systemBackground), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }

            VStack(spacing: 12) {
                Text(rec.title)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                HStack(spacing: 8) {
                    Text(rec.source.label)
                    Text("·")
                    Text(formatDuration(rec.duration))
                    Text("·")
                    Text(rec.createdAt, format: .dateTime.month().day().hour().minute())
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                if !summaryLine.isEmpty {
                    Text(summaryLine)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 28)
                }
                HStack(spacing: 8) {
                    StatusChip(rec: rec)
                    if rec.isFavorite {
                        Chip(icon: "star.fill", text: "收藏", tint: .yellow)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .contentShape(Rectangle())
    }

    private var summaryLine: String { previewText(for: rec) }
}

struct PosterCard: View {
    let rec: Recording
    var width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverArt(seed: rec.id, cornerRadius: 20, barCount: 18)
                .frame(width: width, height: width * 1.3)
                .overlay(alignment: .bottomLeading) {
                    Text(formatDuration(rec.duration))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    if rec.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(7)
                            .background(.black.opacity(0.3), in: Circle())
                            .padding(8)
                    }
                }
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
            Text(rec.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
            Text(rec.createdAt, format: .dateTime.month().day())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct RecordingRow: View {
    let rec: Recording

    var body: some View {
        HStack(spacing: 14) {
            CoverArt(seed: rec.id, cornerRadius: 14, barCount: 9)
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: rec.source.icon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rec.title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                    if rec.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                let p = previewText(for: rec)
                if !p.isEmpty {
                    Text(p)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(rec.createdAt, format: .dateTime.hour().minute())
                    Text(formatDuration(rec.duration))
                    StatusChip(rec: rec, compact: true)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct StatusChip: View {
    let rec: Recording
    var compact = false
    @ObservedObject private var processor = Processor.shared

    var body: some View {
        switch rec.status {
        case .transcribing:
            Chip(icon: "waveform", text: "转写中 \(Int((processor.progress[rec.id] ?? 0) * 100))%", tint: .orange)
        case .organizing:
            Chip(icon: "sparkles", text: "整理中", tint: Theme.ai)
        case .failed:
            Chip(icon: "exclamationmark.triangle.fill", text: "失败", tint: .red)
        case .done:
            if !rec.summary.isEmpty {
                Chip(icon: "sparkles", text: "已整理", tint: Theme.ai)
            } else if rec.hasSpeech, !compact {
                Chip(icon: "text.alignleft", text: "已转写", tint: .secondary)
            }
        case .idle:
            EmptyView()
        }
    }
}

struct RowMenu: View {
    let rec: Recording
    var onDelete: () -> Void

    var body: some View {
        Button {
            rec.isFavorite.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Label(rec.isFavorite ? "取消收藏" : "收藏", systemImage: rec.isFavorite ? "star.slash" : "star")
        }
        ShareLink(item: rec.fileURL) { Label("分享录音", systemImage: "square.and.arrow.up") }
        Divider()
        Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        HStack {
            Text(text)
                .font(.system(.title3, design: .rounded).weight(.bold))
            Spacer()
        }
        .padding(.horizontal, 20)
    }
}

struct EmptyHero: View {
    var body: some View {
        VStack(spacing: 18) {
            CoverArt(seed: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, cornerRadius: 36, barCount: 22)
                .frame(width: 180, height: 180)
                .shadow(color: Theme.accent.opacity(0.3), radius: 24, y: 10)
            Text("开始你的第一段录音")
                .font(.system(.title2, design: .rounded).weight(.bold))
            VStack(alignment: .leading, spacing: 8) {
                Label("点下方「开始录音」，锁屏也能继续", systemImage: "mic")
                Label("手表上录的会自动同步过来", systemImage: "applewatch")
                Label("右上角导入，或从语音备忘录分享", systemImage: "square.and.arrow.down")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }
}

struct DayGroup: Identifiable {
    let id: Date
    let title: String
    let items: [Recording]

    static func make(_ recs: [Recording]) -> [DayGroup] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: recs) { cal.startOfDay(for: $0.createdAt) }
        return dict.keys.sorted(by: >).map { DayGroup(id: $0, title: title(for: $0), items: dict[$0] ?? []) }
    }

    static func title(for d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日 EEEE" : "yyyy年M月d日"
        return f.string(from: d)
    }
}

@MainActor
func deleteRecording(_ rec: Recording, context: ModelContext) {
    try? FileManager.default.removeItem(at: rec.fileURL)
    context.delete(rec)
    try? context.save()
}

/// 列表里显示的一行预览：优先摘要，没有就原文开头
func previewText(for rec: Recording) -> String {
    let source: String
    if !rec.summary.isEmpty {
        let clean = OrganizedParser.stripMarkers(rec.summary)
        let lines = clean.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("#") && $0.contains("摘要") }) {
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

// MARK: - 收藏

struct FavoritesView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Recording> { $0.isFavorite }, sort: \Recording.createdAt, order: .reverse)
    private var favorites: [Recording]
    @State private var toDelete: Recording?

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if favorites.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "star")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("还没有收藏").font(.headline)
                        Text("在录音详情右上角点 ☆，或长按列表里的录音收藏")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 160)
                    .padding(.horizontal, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(favorites) { rec in
                            NavigationLink(value: rec) {
                                GeometryReader { geo in
                                    PosterCard(rec: rec, width: geo.size.width)
                                }
                                .aspectRatio(0.62, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { RowMenu(rec: rec) { toDelete = rec } }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("收藏")
            .navigationDestination(for: Recording.self) { RecordingDetailView(rec: $0) }
            .confirmationDialog("删除这条录音？", isPresented: Binding(
                get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }
            ), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let r = toDelete { deleteRecording(r, context: context) }
                }
            }
        }
    }
}

// MARK: - 搜索

struct SearchView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var query = ""
    @State private var toDelete: Recording?

    private var results: [Recording] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recordings }
        return recordings.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.transcript.localizedCaseInsensitiveContains(q)
                || $0.summary.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, rec in
                        NavigationLink(value: rec) {
                            VStack(alignment: .leading, spacing: 0) {
                                RecordingRow(rec: rec)
                                if let hit = snippet(rec) {
                                    Text(hit)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .padding(.leading, 84)
                                        .padding(.trailing, 14)
                                        .padding(.bottom, 10)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { RowMenu(rec: rec) { toDelete = rec } }
                        if i < results.count - 1 { Divider().padding(.leading, 84) }
                    }
                }
                .padding(.vertical, 6)
                .cardBackground(cornerRadius: 24)
                .padding(16)
                .opacity(results.isEmpty ? 0 : 1)
            }
            .overlay {
                if results.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "搜索标题、原文和整理内容")
            .navigationDestination(for: Recording.self) { RecordingDetailView(rec: $0) }
            .confirmationDialog("删除这条录音？", isPresented: Binding(
                get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }
            ), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let r = toDelete { deleteRecording(r, context: context) }
                }
            }
        }
    }

    /// 命中原文的那一小段
    private func snippet(_ rec: Recording) -> AttributedString? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let r = rec.transcript.range(of: q, options: .caseInsensitive) else { return nil }
        let lo = rec.transcript.index(r.lowerBound, offsetBy: -14, limitedBy: rec.transcript.startIndex) ?? rec.transcript.startIndex
        let hi = rec.transcript.index(r.upperBound, offsetBy: 30, limitedBy: rec.transcript.endIndex) ?? rec.transcript.endIndex
        var a = AttributedString((lo > rec.transcript.startIndex ? "…" : "") + rec.transcript[lo..<hi].replacingOccurrences(of: "\n", with: " "))
        if let ar = a.range(of: q, options: .caseInsensitive) {
            a[ar].foregroundColor = Theme.accent
            a[ar].font = .footnote.bold()
        }
        return a
    }
}

// MARK: - 底部录音条（iOS 26 放在标签栏上方）

struct RecordAccessoryModifier: ViewModifier {
    @ObservedObject var recorder: PhoneRecorder
    var onError: (String) -> Void

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.tabViewBottomAccessory {
                RecordAccessory(recorder: recorder, onError: onError)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            RecordAccessory(recorder: recorder, onError: onError)
                .padding(.vertical, 10)
                .glassBackground(cornerRadius: 30)
                .padding(.horizontal, 16)
                .padding(.bottom, 64)
        }
    }
}

struct RecordAccessory: View {
    @ObservedObject var recorder: PhoneRecorder
    var onError: (String) -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.recordGradient)
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 11, height: 11)
                    } else {
                        Image(systemName: "mic.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 32, height: 32)
                .scaleEffect(recorder.isRecording && pulse ? 1.08 : 1)

                if recorder.isRecording {
                    Text(formatDuration(recorder.elapsed))
                        .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                    LiveLevels(levels: Array(recorder.levels.suffix(24)))
                        .frame(maxWidth: .infinity, maxHeight: 26)
                        .clipped()
                    Text("停止")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("开始录音")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    Spacer()
                    Text("锁屏也能录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onChange(of: recorder.isRecording) { _, rec in
            if rec {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                pulse = false
            }
        }
    }

    private func toggle() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if recorder.isRecording {
            if let r = recorder.stop() {
                Processor.shared.ingest(fileName: r.fileName, source: .phone, createdAt: r.startedAt)
                Processor.shared.showToast("已保存，正在转写")
            }
        } else {
            Task {
                do { try await recorder.start() } catch { onError(error.localizedDescription) }
            }
        }
    }
}
