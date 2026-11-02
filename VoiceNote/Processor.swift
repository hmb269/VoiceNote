import AVFoundation
import Foundation
import SwiftData
import UIKit

private final class StreamBox: @unchecked Sendable {
    var lastUI = Date.distantPast
    var finished = false
}

/// 负责：新录音入库、转写、AI 整理。所有任务排队一个一个跑。
@MainActor
final class Processor: ObservableObject {
    static let shared = Processor()

    var container: ModelContainer? = DataStore.shared
    @Published var progress: [UUID: Double] = [:]
    /// 转写阶段说明，比如「区分说话人」
    @Published var stage: [UUID: String] = [:]
    @Published var busy: Set<UUID> = [] {
        didSet { BackgroundKeeper.shared.update(active: !busy.isEmpty) }
    }
    @Published var lastError: String?
    @Published var toast: String?
    /// 整理进度说明，比如「思考中」「已写 1200 字」
    @Published var organizeInfo: [UUID: String] = [:]
    /// 正在总结重点的录音
    @Published var summarizing: Set<UUID> = []
    /// 正在填会议记录表的录音，值是进度说明
    @Published var formFilling: [UUID: String] = [:]

    func fillForm(_ rec: Recording, template: WordTemplate, using ref: ModelRef? = nil) {
        let id = rec.id
        guard formFilling[id] == nil else { return }
        guard rec.hasSpeech else { lastError = "先转写，再填表"; return }
        let r = ref ?? AppConfig.modelFor(.meeting)
        formFilling[id] = "正在连接 \(r.model)…"
        Task { @MainActor in
            defer { self.formFilling[id] = nil }
            do {
                let form = try await FormFiller.fill(template: template, rec: rec, ref: r) { text, thinking in
                    Task { @MainActor in
                        guard self.formFilling[id] != nil else { return }
                        self.formFilling[id] = text.isEmpty ? (thinking > 0 ? "模型在思考…" : "等待模型回复…")
                                                            : "正在填写，已写 \(text.count) 字"
                    }
                }
                rec.filledForm = form
                self.save()
                self.showToast("会议记录表已填好")
            } catch {
                self.lastError = "填表失败：\(error.localizedDescription)"
            }
        }
    }

    func summarizeHighlights(_ rec: Recording, using override: ModelRef? = nil) {
        let id = rec.id
        guard !summarizing.contains(id) else { return }
        let items = rec.highlights
            .sorted { ($0.start ?? .greatestFiniteMagnitude) < ($1.start ?? .greatestFiniteMagnitude) }
            .map(\.text)
        guard !items.isEmpty else { return }
        let ref = override ?? AppConfig.modelFor(.general)
        guard let key = Keychain.get(ref.provider.keyName) else {
            lastError = "还没填 \(ref.provider.label) 的 API Key，到 设置 → 服务商与密钥 里填"
            return
        }
        summarizing.insert(id)
        let old = rec.highlightSummary
        let box = StreamBox()
        Task { @MainActor in
            defer { self.summarizing.remove(id) }
            do {
                let md = try await Organizer.summarizeHighlights(
                    items, provider: ref.provider, apiKey: key,
                    baseURL: AppConfig.llmBaseURL(ref.provider), model: ref.model
                ) { text, _ in
                    Task { @MainActor in
                        guard !box.finished, !text.isEmpty, Date().timeIntervalSince(box.lastUI) > 0.4 else { return }
                        box.lastUI = Date()
                        rec.highlightSummary = Organizer.clean(text)
                    }
                }
                box.finished = true
                rec.highlightSummary = md
            } catch {
                box.finished = true
                rec.highlightSummary = old
                self.lastError = "总结重点失败：\(error.localizedDescription)"
            }
            self.save()
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if self.toast == text { self.toast = nil }
        }
    }

    private var chain: Task<Void, Never>?

    private var context: ModelContext? { container?.mainContext }

    private func save() {
        try? context?.save()
    }

    // MARK: 取消

    /// 每次转写/整理的令牌：取消或重开后，旧任务回来发现令牌不对就不再改数据
    private var tokens: [UUID: UUID] = [:]
    private var cancelers: [UUID: () -> Void] = [:]
    private var summaryBackup: [UUID: String] = [:]

    /// 跑一个可以随时取消的任务：点取消立刻返回，不用等底层（比如本机区分说话人）真的停下
    private func cancellable<T>(_ id: UUID, _ op: @escaping @MainActor () async throws -> T) async throws -> T {
        let race = Race<T>()
        // 都在主线程：任务要等下面挂起后才会开始跑，所以 cont 一定先设好
        let t = Task { @MainActor in
            do { race.finish(.success(try await op())) } catch { race.finish(.failure(error)) }
        }
        cancelers[id] = {
            t.cancel()
            race.finish(.failure(CancellationError()))
        }
        return try await withCheckedThrowingContinuation { c in race.cont = c }
    }

    func cancel(_ rec: Recording) {
        let id = rec.id
        cancelers[id]?()
        cancelers[id] = nil
        tokens[id] = nil
        busy.remove(id)
        progress[id] = nil
        stage[id] = nil
        organizeInfo[id] = nil
        UserDefaults.standard.removeObject(forKey: "resumeEngine-\(id)")
        if rec.status == .transcribing {
            rec.status = rec.hasSpeech ? .done : .idle
        } else if rec.status == .organizing {
            if let old = summaryBackup[id] { rec.summary = old }
            rec.status = .done
        }
        summaryBackup[id] = nil
        save()
        showToast("已取消")
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    // MARK: 入库

    func ingest(fileName: String, source: RecordingSource, createdAt: Date, title: String? = nil) {
        guard let context else { return }
        let url = Storage.recordingsDir.appendingPathComponent(fileName)
        let rec = Recording(title: title ?? Recording.defaultTitle(for: createdAt, source: source),
                            createdAt: createdAt,
                            duration: AudioTools.duration(of: url),
                            fileName: fileName,
                            source: source)
        context.insert(rec)
        save()
        if AppConfig.autoTranscribe {
            enqueue { await self.autoProcess(rec) }
        } else {
            rec.autoPending = false
            save()
        }
    }

    func importFiles(_ urls: [URL]) {
        Task { @MainActor in
            var ok = 0
            for u in urls {
                if await importOne(u) { ok += 1 }
            }
            if ok > 0 { showToast(ok == 1 ? "已导入，正在转写" : "已导入 \(ok) 个，正在转写") }
        }
    }

    func importFile(_ url: URL) {
        importFiles([url])
    }

    private func importOne(_ url: URL) async -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let title = url.deletingPathExtension().lastPathComponent
        let isVideo = ["mp4", "mov", "m4v"].contains(ext)
        let name = "\(UUID().uuidString).\(isVideo || ext.isEmpty ? "m4a" : ext)"
        let dest = Storage.recordingsDir.appendingPathComponent(name)
        do {
            if isVideo {
                // 视频先抽出音轨
                let asset = AVURLAsset(url: url)
                guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw VNError("这个视频没有音轨")
                }
                s.outputURL = dest
                s.outputFileType = .m4a
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    s.exportAsynchronously { c.resume() }
                }
                guard s.status == .completed else {
                    throw VNError(s.error?.localizedDescription ?? "提取音频失败")
                }
            } else {
                try FileManager.default.copyItem(at: url, to: dest)
                // 后缀和真实格式不符（比如叫 .mp3 其实是 aac），按真实格式改名
                if !AudioTools.isReadable(dest), let real = AudioTools.sniffExtension(dest), real != ext {
                    let fixed = Storage.recordingsDir.appendingPathComponent("\(UUID().uuidString).\(real)")
                    try FileManager.default.moveItem(at: dest, to: fixed)
                    if AudioTools.isReadable(fixed), !AudioTools.looksTruncated(fixed) {
                        ingest(fileName: fixed.lastPathComponent, source: .imported, createdAt: created, title: title)
                        return true
                    }
                    try FileManager.default.moveItem(at: fixed, to: dest)
                }
                // 系统读不了的格式（aac 裸流、amr 等），或只读出一小段的（文件头长度写错），转成 m4a
                if !AudioTools.isReadable(dest) || AudioTools.looksTruncated(dest) {
                    let m4a = Storage.recordingsDir.appendingPathComponent("\(UUID().uuidString).m4a")
                    try await AudioTools.convertToM4A(dest, dest: m4a)
                    if AudioTools.duration(of: m4a) < 1 {
                        try? FileManager.default.removeItem(at: m4a)
                        throw VNError("没读出声音（文件头：\(AudioTools.headHex(dest))）。请把文件发给开发者看看")
                    }
                    try? FileManager.default.removeItem(at: dest)
                    ingest(fileName: m4a.lastPathComponent, source: .imported, createdAt: created, title: title)
                    return true
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            lastError = "导入「\(title)」失败：\(error.localizedDescription)"
            return false
        }
        ingest(fileName: name, source: .imported, createdAt: created, title: title)
        return true
    }

    /// App 回到前台时：修复中断的状态，补跑手表传来但还没处理的录音
    func resumePending() {
        guard let context else { return }
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        var toResume: [(Recording, ASREngine)] = []
        for rec in all where !busy.contains(rec.id) {
            // 文字已经存下来的（卡在区分说话人）就不再自动重跑，免得手机又发烫
            if rec.status == .transcribing, !rec.hasSpeech,
               let raw = UserDefaults.standard.string(forKey: "resumeEngine-\(rec.id)"),
               let engine = ASREngine(rawValue: raw) {
                toResume.append((rec, engine))
            }
            if rec.status == .transcribing || rec.status == .organizing {
                rec.status = rec.transcript.isEmpty ? .idle : .done
            }
        }
        save()
        for (rec, engine) in toResume {
            rec.status = .transcribing
            enqueue { await self.transcribe(rec, engine: engine) }
        }
        let resuming = Set(toResume.map { $0.0.id })
        guard AppConfig.autoTranscribe else { return }
        for rec in all where rec.autoPending && !resuming.contains(rec.id) && rec.transcript.isEmpty && !busy.contains(rec.id) {
            enqueue { await self.autoProcess(rec) }
        }
    }

    private func autoProcess(_ rec: Recording) async {
        rec.autoPending = false
        save()
        guard rec.transcript.isEmpty else { return }
        await transcribe(rec, engine: AppConfig.asrEngine)
        // 只有一两句话的录音不自动整理，需要的话手动点「AI 整理」
        if rec.status == .done, rec.hasSpeech, rec.transcript.count >= 40, AppConfig.autoOrganize,
           Keychain.get(AppConfig.llmProvider.keyName) != nil {
            await organize(rec)
        }
    }

    // MARK: 手动操作（从详情页点按钮）

    func requestTranscribe(_ rec: Recording, engine: ASREngine) {
        enqueue { await self.transcribe(rec, engine: engine) }
    }

    /// style 为空用设置里的默认方式；model 不为空时临时换用这个服务商和模型
    func requestOrganize(_ rec: Recording, style: OrganizeStyle? = nil,
                         using model: (LLMProvider, String)? = nil) {
        enqueue { await self.organize(rec, style: style ?? AppConfig.organizeStyle, using: model) }
    }

    // MARK: 转写

    private func transcribe(_ rec: Recording, engine: ASREngine) async {
        let id = rec.id
        guard !busy.contains(id) else { return }
        busy.insert(id)
        progress[id] = 0
        let token = UUID()
        tokens[id] = token
        let bgTask = BGTaskBox.begin("transcribe")
        defer {
            bgTask.end()
            if tokens[id] == token {
                busy.remove(id)
                progress[id] = nil
                tokens[id] = nil
                cancelers[id] = nil
            }
        }

        rec.status = .transcribing
        rec.errorMessage = ""
        save()
        // 记下正在用的引擎：App 中途被系统关掉，下次打开从断点接着转
        UserDefaults.standard.set(engine.rawValue, forKey: "resumeEngine-\(id)")
        defer { if tokens[id] == token { UserDefaults.standard.removeObject(forKey: "resumeEngine-\(id)") } }

        var url = rec.fileURL
        // 以前导入的、系统读不了的格式，转写前先转成 m4a
        if !AudioTools.isReadable(url) || AudioTools.looksTruncated(url) {
            let m4a = Storage.recordingsDir.appendingPathComponent("\(UUID().uuidString).m4a")
            do {
                try await AudioTools.convertToM4A(url, dest: m4a)
                try? FileManager.default.removeItem(at: url)
                rec.fileName = m4a.lastPathComponent
                rec.duration = AudioTools.duration(of: m4a)
                url = m4a
                save()
            } catch {
                rec.status = .failed
                rec.errorMessage = "转写失败：\(error.localizedDescription)"
                save()
                return
            }
        }
        let report: (Double) -> Void = { p in
            Task { @MainActor in Processor.shared.progress[id] = p }
        }
        do {
            let segs = try await cancellable(id) {
                try await Transcription.run(url, engine: engine, progress: report) { segs in
                    guard self.tokens[id] == token else { return }
                    // 文字先存下来，区分说话人慢或失败都不影响
                    rec.segments = segs
                    rec.engineUsed = engine.shortLabel
                    self.stage[id] = "正在区分说话人"
                    self.save()
                }
            }
            guard tokens[id] == token else { return }
            stage[id] = nil
            rec.segments = segs
            ChunkCache.clear(url)
            rec.engineUsed = engine.shortLabel
            rec.status = .done
        } catch {
            guard tokens[id] == token else { return }
            stage[id] = nil
            rec.status = .failed
            rec.errorMessage = "转写失败：\(error.localizedDescription)"
        }
        save()
    }

    // MARK: 校对

    func updateSegment(_ rec: Recording, id: UUID, text: String) {
        var segs = rec.segments
        guard let i = segs.firstIndex(where: { $0.id == id }) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            segs.remove(at: i)
        } else {
            segs[i].text = t
        }
        rec.segments = segs
        save()
    }

    // MARK: 整理

    private func organize(_ rec: Recording, style: OrganizeStyle = AppConfig.organizeStyle,
                          using override: (LLMProvider, String)? = nil) async {
        let id = rec.id
        guard !busy.contains(id) else { return }
        guard rec.hasSpeech else {
            rec.errorMessage = "还没有可整理的文字，先转写"
            return
        }
        let ref = override.map { ModelRef($0.0, $0.1) } ?? AppConfig.modelFor(style)
        let provider = ref.provider
        let modelName = ref.model
        guard let key = Keychain.get(provider.keyName) else {
            rec.errorMessage = "还没填 \(provider.label) 的 API Key，到 设置 → 服务商与密钥 里填"
            rec.status = .failed
            save()
            return
        }
        busy.insert(id)
        let token = UUID()
        tokens[id] = token
        let bgTask = BGTaskBox.begin("organize")
        defer {
            bgTask.end()
            if tokens[id] == token {
                busy.remove(id)
                tokens[id] = nil
                cancelers[id] = nil
                summaryBackup[id] = nil
            }
        }

        rec.status = .organizing
        rec.errorMessage = ""
        save()
        let oldSummary = rec.summary
        summaryBackup[id] = oldSummary
        organizeInfo[id] = "正在连接 \(modelName)…"
        defer { if tokens[id] == token { organizeInfo[id] = nil } }

        let box = StreamBox()
        let onProgress: (String, Int) -> Void = { text, thinking in
            Task { @MainActor in
                let p = Processor.shared
                guard !box.finished, p.tokens[id] == token, Date().timeIntervalSince(box.lastUI) > 0.5 else { return }
                box.lastUI = Date()
                if text.isEmpty {
                    p.organizeInfo[id] = thinking > 0 ? "模型还在内部思考（已想 \(thinking) 字，不算结果）…" : "等待模型回复…"
                } else {
                    p.organizeInfo[id] = "正在写，已写 \(text.count) 字"
                    rec.summary = Organizer.clean(text)
                }
            }
        }

        do {
            let transcript = rec.transcript, segments = rec.segments
            let md = try await cancellable(id) { try await Organizer.organize(transcript: transcript,
                                                  segments: segments,
                                                  provider: provider,
                                                  apiKey: key,
                                                  baseURL: AppConfig.llmBaseURL(provider),
                                                  model: modelName,
                                                  style: style,
                                                  onProgress: onProgress) }
            box.finished = true
            guard tokens[id] == token else { return }
            rec.summary = md
            rec.organizedModel = modelName
            rec.organizedStyle = style.rawValue
            if style == .meeting, TemplateStore.autoFill, let t = TemplateStore.defaultTemplate {
                fillForm(rec, template: t, using: ModelRef(provider, modelName))
            }
            if let t = Organizer.extractTitle(md) { rec.title = t }
            rec.status = .done
        } catch {
            box.finished = true
            guard tokens[id] == token else { return }
            rec.summary = oldSummary
            rec.status = .failed
            rec.errorMessage = "整理失败：\(error.localizedDescription)"
        }
        save()
    }
}

/// 后台任务：到时间自己结束，不让系统因为超时把 App 杀掉
@MainActor
final class BGTaskBox {
    private var id: UIBackgroundTaskIdentifier = .invalid
    static func begin(_ name: String) -> BGTaskBox {
        let b = BGTaskBox()
        b.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak b] in
            MainActor.assumeIsolated { b?.end() }
        }
        return b
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// 谁先到用谁：任务完成或用户点取消（只在主线程上用）
final class Race<T>: @unchecked Sendable {
    var cont: CheckedContinuation<T, Error>?
    func finish(_ r: Result<T, Error>) {
        cont?.resume(with: r)
        cont = nil
    }
}
