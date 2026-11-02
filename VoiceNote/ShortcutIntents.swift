import AppIntents
import Foundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - 选项

enum ShortcutEngine: String, AppEnum {
    case byDefault, apple, siliconflow, aliyun

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "转写方式"
    static var caseDisplayRepresentations: [ShortcutEngine: DisplayRepresentation] = [
        .byDefault: "按 App 设置",
        .apple: "苹果本机（免费）",
        .siliconflow: "硅基流动 SenseVoice",
        .aliyun: "阿里云百炼",
    ]

    var engine: ASREngine {
        switch self {
        case .byDefault: return AppConfig.asrEngine
        case .apple: return .apple
        case .siliconflow: return .siliconflow
        case .aliyun: return .aliyun
        }
    }
}

enum ShortcutStyle: String, AppEnum {
    case byDefault, general, meeting, conversation, lecture

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "整理方式"
    static var caseDisplayRepresentations: [ShortcutStyle: DisplayRepresentation] = [
        .byDefault: "按 App 设置",
        .general: "通用整理",
        .meeting: "会议纪要",
        .conversation: "谈话/通话",
        .lecture: "课堂/讲座",
    ]

    var style: OrganizeStyle {
        switch self {
        case .byDefault: return AppConfig.organizeStyle
        case .general: return .general
        case .meeting: return .meeting
        case .conversation: return .conversation
        case .lecture: return .lecture
        }
    }
}

enum ShortcutContent: String, AppEnum {
    case organized, transcript, title

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "内容"
    static var caseDisplayRepresentations: [ShortcutContent: DisplayRepresentation] = [
        .organized: "整理结果（没有就给原文）",
        .transcript: "转写原文",
        .title: "标题",
    ]
}

// MARK: - 共用逻辑

@MainActor
enum ShortcutWorker {
    static func transcribe(_ url: URL, engine: ASREngine) async throws -> [TranscriptSegment] {
        switch engine {
        case .apple:
            return try await AppleTranscriber.transcribe(url: url, localeID: AppConfig.appleLocale) { _ in }
        case .siliconflow:
            guard let key = Keychain.get(.siliconflow) else {
                throw VNError("还没在 App 设置里填硅基流动的 API Key")
            }
            return try await SiliconTranscriber.transcribe(url: url, apiKey: key,
                                                           model: AppConfig.siliconModel) { _ in }
        case .aliyun:
            guard let key = Keychain.get(.aliyun) else {
                throw VNError("还没在 App 设置里填阿里云百炼的 API Key")
            }
            return try await AliyunTranscriber.transcribe(url: url, apiKey: key,
                                                          baseURL: AppConfig.aliyunBaseURL,
                                                          model: AppConfig.aliyunModel,
                                                          language: AppConfig.aliyunLanguage) { _ in }
        }
    }

    static func organize(_ text: String, segments: [TranscriptSegment],
                         style: OrganizeStyle = AppConfig.organizeStyle) async throws -> String {
        let ref = AppConfig.modelFor(style)
        let p = ref.provider
        guard let key = Keychain.get(p.keyName) else {
            throw VNError("还没在 App 设置里填 \(p.label) 的 API Key")
        }
        return try await Organizer.organize(transcript: text, segments: segments, provider: p,
                                            apiKey: key, baseURL: AppConfig.llmBaseURL(p),
                                            model: ref.model, style: style)
    }

    /// 把快捷指令传进来的文件存到录音目录
    static func store(_ file: IntentFile) throws -> (fileName: String, title: String) {
        let original = file.filename
        let ext = (original as NSString).pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext.isEmpty ? "m4a" : ext)"
        let dest = Storage.recordingsDir.appendingPathComponent(name)
        if let src = file.fileURL {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: src, to: dest)
        } else {
            try file.data.write(to: dest)
        }
        let title = (original as NSString).deletingPathExtension
        return (name, title.isEmpty ? Recording.defaultTitle(for: Date(), source: .imported) : title)
    }
}

// MARK: - 转写音频（静默）

struct TranscribeAudioIntent: AppIntent {
    static var title: LocalizedStringResource = "转写音频"
    static var description = IntentDescription("把音频转成文字，可以顺便 AI 整理。不会打开 App。")
    static var openAppWhenRun = false

    @Parameter(title: "音频", supportedContentTypes: [.audio])
    var file: IntentFile

    @Parameter(title: "转写方式", default: .byDefault)
    var engine: ShortcutEngine

    @Parameter(title: "AI 整理", default: false)
    var organize: Bool

    @Parameter(title: "整理方式", default: .byDefault)
    var style: ShortcutStyle

    @Parameter(title: "保存到录音列表", default: true)
    var save: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("转写\(\.$file)") {
            \.$engine
            \.$organize
            \.$style
            \.$save
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let stored = try ShortcutWorker.store(file)
        let url = Storage.recordingsDir.appendingPathComponent(stored.fileName)
        let asr = engine.engine
        let segs: [TranscriptSegment]
        do {
            segs = try await ShortcutWorker.transcribe(url, engine: asr)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let text = segs.map(\.text).joined(separator: "\n")
        var summary = ""
        if organize, !text.isEmpty {
            summary = try await ShortcutWorker.organize(text, segments: segs, style: style.style)
        }

        if save {
            let ctx = DataStore.shared.mainContext
            let rec = Recording(title: stored.title, createdAt: Date(),
                                duration: AudioTools.duration(of: url),
                                fileName: stored.fileName, source: .imported)
            rec.segments = segs
            rec.summary = summary
            if let t = Organizer.extractTitle(summary) { rec.title = t }
            rec.engineUsed = asr.shortLabel
            rec.status = .done
            rec.autoPending = false
            ctx.insert(rec)
            try? ctx.save()
        } else {
            try? FileManager.default.removeItem(at: url)
        }

        let out = summary.isEmpty ? text : OrganizedParser.stripMarkers(summary)
        return .result(value: out.isEmpty ? Recording.noSpeechText : out)
    }
}

// MARK: - AI 整理文字（静默）

struct OrganizeTextIntent: AppIntent {
    static var title: LocalizedStringResource = "AI 整理文字"
    static var description = IntentDescription("把一段文字整理成标题、摘要、要点、待办和正文。不会打开 App。")
    static var openAppWhenRun = false

    @Parameter(title: "文字", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "整理方式", default: .byDefault)
    var style: ShortcutStyle

    static var parameterSummary: some ParameterSummary {
        Summary("把\(\.$text)整理成\(\.$style)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw VNError("没有文字可整理") }
        let md = try await ShortcutWorker.organize(t, segments: [], style: style.style)
        return .result(value: OrganizedParser.stripMarkers(md))
    }
}

// MARK: - 导入录音（静默，后台转写）

struct ImportAudioIntent: AppIntent {
    static var title: LocalizedStringResource = "导入录音"
    static var description = IntentDescription("把音频放进录音列表，按 App 设置自动转写和整理。没处理完的下次打开 App 会接着做。")
    static var openAppWhenRun = false

    @Parameter(title: "音频", supportedContentTypes: [.audio])
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("导入\(\.$files)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        var n = 0
        for f in files {
            let stored = try ShortcutWorker.store(f)
            Processor.shared.ingest(fileName: stored.fileName, source: .imported,
                                    createdAt: Date(), title: stored.title)
            n += 1
        }
        return .result(value: n)
    }
}

// MARK: - 获取最近的录音（静默）

struct LatestRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "获取最近的录音"
    static var description = IntentDescription("返回最近一条录音的整理结果、原文或标题。")
    static var openAppWhenRun = false

    @Parameter(title: "内容", default: .organized)
    var content: ShortcutContent

    @Parameter(title: "只要收藏的", default: false)
    var favoritesOnly: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("获取最近录音的\(\.$content)") {
            \.$favoritesOnly
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        var d = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if favoritesOnly {
            d.predicate = #Predicate<Recording> { $0.isFavorite }
        }
        d.fetchLimit = 1
        guard let rec = try DataStore.shared.mainContext.fetch(d).first else {
            throw VNError("还没有录音")
        }
        switch content {
        case .title:
            return .result(value: rec.title)
        case .transcript:
            return .result(value: rec.transcript.isEmpty ? "（还没转写）" : rec.transcript)
        case .organized:
            if !rec.summary.isEmpty { return .result(value: OrganizedParser.stripMarkers(rec.summary)) }
            return .result(value: rec.transcript.isEmpty ? "（还没转写）" : rec.transcript)
        }
    }
}

// MARK: - 录音开关

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "开始录音"
    static var description = IntentDescription("打开 App 并开始录音。苹果规定从后台启动麦克风必须先把 App 打开。")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let r = PhoneRecorder.shared
        if !r.isRecording {
            try await r.start()
        }
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "停止录音"
    static var description = IntentDescription("停止正在进行的录音并保存，按设置自动转写。不会打开 App。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let r = PhoneRecorder.shared.stop() else {
            return .result(value: "现在没有在录音")
        }
        Processor.shared.ingest(fileName: r.fileName, source: .phone, createdAt: r.startedAt)
        return .result(value: "已保存")
    }
}

// MARK: - Siri / 快捷指令里直接出现的入口

struct VoiceNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["用\(.applicationName)开始录音", "\(.applicationName)开始录音"],
                    shortTitle: "开始录音",
                    systemImageName: "mic.fill")
        AppShortcut(intent: StopRecordingIntent(),
                    phrases: ["\(.applicationName)停止录音"],
                    shortTitle: "停止录音",
                    systemImageName: "stop.fill")
        AppShortcut(intent: TranscribeAudioIntent(),
                    phrases: ["用\(.applicationName)转写音频"],
                    shortTitle: "转写音频",
                    systemImageName: "text.bubble")
        AppShortcut(intent: LatestRecordingIntent(),
                    phrases: ["\(.applicationName)最近的录音"],
                    shortTitle: "最近的录音",
                    systemImageName: "clock")
    }
}
