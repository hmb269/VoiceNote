import SwiftUI
import SwiftData
import UIKit

enum RootTab: Hashable {
    case home, favorites, record, importFile, settings, search
}

struct ContentView: View {
    @ObservedObject private var processor = Processor.shared
    @AppStorage("appearance") private var appearance = 1
    @State private var tab: RootTab = .home
    @State private var lastTab: RootTab = .home
    @State private var alertText: String?
    @State private var showPicker = false
    @ObservedObject private var recorder = PhoneRecorder.shared

    /// 「录音」「导入」是动作，不切页面
    private var selection: Binding<RootTab> {
        Binding(get: { tab }, set: { new in
            switch new {
            case .record:
                toggleRecording(recorder)
            case .importFile:
                showPicker = true
            default:
                if new != tab {
                    if tab != .search { lastTab = tab }
                    tab = new
                }
            }
        })
    }

    private var scheme: ColorScheme? {
        switch appearance {
        case 1: return .dark
        case 2: return .light
        default: return nil
        }
    }

    var body: some View {
        TabView(selection: selection) {
            Tab("首页", systemImage: "waveform", value: RootTab.home) {
                HomeView()
            }
            Tab("收藏", systemImage: "star.fill", value: RootTab.favorites) {
                FavoritesView()
            }
            Tab("搜索", systemImage: "magnifyingglass", value: RootTab.search) {
                SearchView { withAnimation { tab = lastTab } }
            }
            Tab("设置", systemImage: "gearshape.fill", value: RootTab.settings) {
                SettingsView(showDone: false)
            }
            // 录音放在右边单独的圆键里，不容易误触
            Tab(recorder.isRecording ? formatDuration(recorder.elapsed) : "录音",
                systemImage: recorder.isRecording ? "stop.fill" : "mic.fill",
                value: RootTab.record,
                role: .search) {
                Color.clear
            }
        }
        .overlay(alignment: .bottom) {
            if recorder.isRecording {
                RecordingBanner(recorder: recorder)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 92)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: recorder.isRecording)

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
    @State private var showCalendar = false
    @State private var showPicker = false
    @State private var toDelete: Recording?
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    private var weekDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
    }

    private func items(on day: Date) -> [Recording] {
        let cal = Calendar.current
        return recordings.filter { cal.isDate($0.createdAt, inSameDayAs: day) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    weekSection
                    if recordings.isEmpty {
                        EmptyHero()
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Recording.self) { RecordingDetailView(rec: $0) }
            .navigationDestination(for: String.self) { key in
                if key == "all" { AllRecordingsView() }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker { urls in Processor.shared.importFiles(urls) }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showCalendar) {
                CalendarSheet()
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

    // 最近七天：日期条 + 当天的录音
    private var weekSection: some View {
        let dayItems = items(on: selectedDay)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近七天")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Spacer()
                NavigationLink(value: "all") {
                    HStack(spacing: 3) {
                        Text("全部录音")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
                Button { showCalendar = true } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .accessibilityLabel("按日历选择")
                Button { showPicker = true } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .accessibilityLabel("导入音频")
            }
            .padding(.horizontal, 20)

            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { d in
                    DayCell(date: d,
                            selected: Calendar.current.isDate(d, inSameDayAs: selectedDay),
                            count: items(on: d).count)
                        .frame(maxWidth: .infinity)
                        .onTapGesture {
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(.snappy(duration: 0.25)) { selectedDay = d }
                        }
                }
            }
            .padding(.horizontal, 12)

            Group {
                if dayItems.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("这天没有录音").font(.headline)
                        Text("换一天看看，或者点底部的「录音」开始录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 34)
                } else {
                    RecordingList(items: dayItems) { toDelete = $0 }
                }
            }
            .cardBackground(cornerRadius: 24)
            .padding(.horizontal, 16)
            .animation(.snappy(duration: 0.25), value: selectedDay)
        }
    }
}

struct DayCell: View {
    let date: Date
    let selected: Bool
    let count: Int

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE"
        return f
    }()

    var body: some View {
        VStack(spacing: 5) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text(Calendar.current.isDateInToday(date) ? "今天" : Self.weekday.string(from: date))
                .font(.caption.weight(.medium))
                .foregroundStyle(selected ? Theme.accent : Color.secondary)
            Circle()
                .fill(count > 0 ? Theme.accent : Color.clear)
                .frame(width: 5, height: 5)
        }
        .padding(.vertical, 9)
        .frame(width: 48)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 一组录音的行列表（带封面小图标），放在卡片里
struct RecordingList: View {
    let items: [Recording]
    var onDelete: (Recording) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, rec in
                NavigationLink(value: rec) {
                    RecordingRow(rec: rec)
                }
                .buttonStyle(.plain)
                .contextMenu { RowMenu(rec: rec) { onDelete(rec) } }
                if i < items.count - 1 {
                    Divider().padding(.leading, 84)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct AllRecordingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var toDelete: Recording?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(DayGroup.make(recordings)) { g in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(g.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 22)
                        RecordingList(items: g.items) { toDelete = $0 }
                            .cardBackground(cornerRadius: 22)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("全部录音")
        .confirmationDialog("删除这条录音？", isPresented: Binding(
            get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let r = toDelete { deleteRecording(r, context: context) }
            }
        }
    }
}

struct CalendarSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var day = Date()
    @State private var toDelete: Recording?

    private var items: [Recording] {
        recordings.filter { Calendar.current.isDate($0.createdAt, inSameDayAs: day) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DatePicker("选择日期", selection: $day, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                        .tint(Theme.accent)
                        .padding(10)
                        .cardBackground(cornerRadius: 24)

                    HStack {
                        Text(DayGroup.title(for: Calendar.current.startOfDay(for: day)))
                            .font(.headline)
                        Spacer()
                        Text("\(items.count) 条").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)

                    if items.isEmpty {
                        Text("这天没有录音")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                            .cardBackground(cornerRadius: 22)
                    } else {
                        RecordingList(items: items) { toDelete = $0 }
                            .cardBackground(cornerRadius: 22)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("按日期查看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationDestination(for: Recording.self) { RecordingDetailView(rec: $0) }
            .confirmationDialog("删除这条录音？", isPresented: Binding(
                get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }
            ), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let r = toDelete { deleteRecording(r, context: context) }
                }
            }
        }
        .presentationDetents([.large])
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
                Label("点底部的「录音」开始录，锁屏也能继续", systemImage: "mic")
                Label("手表上录的会自动同步过来", systemImage: "applewatch")
                Label("右上角导入，或从语音备忘录分享", systemImage: "square.and.arrow.down")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
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
                    RecordingList(items: favorites) { toDelete = $0 }
                        .cardBackground(cornerRadius: 24)
                        .padding(16)
                }
            }
            .background(Color(.systemGroupedBackground))
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
    var onBack: () -> Void = {}
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
            .overlay(alignment: .leading) {
                // 从屏幕左边缘往右滑，回到上一个页面
                Color.clear
                    .frame(width: 28)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 15)
                            .onEnded { v in
                                if v.translation.width > 60 && abs(v.translation.height) < 80 { onBack() }
                            }
                    )
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { v in
                        if v.startLocation.x < 50 && v.translation.width > 90
                            && abs(v.translation.height) < abs(v.translation.width) / 2 {
                            onBack()
                        }
                    }
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) { Image(systemName: "chevron.left") }
                        .accessibilityLabel("返回")
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

// MARK: - 录音按钮（右上角）和录音中的横幅

struct RecordToolbarButton: View {
    @ObservedObject var recorder: PhoneRecorder

    var body: some View {
        Button(action: { toggleRecording(recorder) }) {
            if recorder.isRecording {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text(formatDuration(recorder.elapsed)).monospacedDigit()
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
            } else {
                Image(systemName: "mic.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
        .accessibilityLabel(recorder.isRecording ? "停止录音" : "开始录音")
    }
}

struct RecordingBanner: View {
    @ObservedObject var recorder: PhoneRecorder
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text("录音中").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(formatDuration(recorder.elapsed))
                    .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
            }
            LiveLevels(levels: Array(recorder.levels.suffix(22)))
                .frame(maxWidth: .infinity)
            Button { toggleRecording(recorder) } label: {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .frame(width: 50, height: 50)
                    .background(Theme.recordGradient, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止录音")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassBackground(cornerRadius: 34)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

@MainActor
func toggleRecording(_ recorder: PhoneRecorder) {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    if recorder.isRecording {
        if let r = recorder.stop() {
            Processor.shared.ingest(fileName: r.fileName, source: .phone, createdAt: r.startedAt)
            Processor.shared.showToast("已保存，正在转写")
        }
    } else {
        Task { @MainActor in
            do { try await recorder.start() } catch { Processor.shared.lastError = error.localizedDescription }
        }
    }
}
