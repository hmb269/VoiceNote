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
    @Published var busy: Set<UUID> = []
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
            }
        } catch {
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
        for rec in all where !busy.contains(rec.id) {
            if rec.status == .transcribing || rec.status == .organizing {
                rec.status = rec.transcript.isEmpty ? .idle : .done
            }
        }
        save()
        guard AppConfig.autoTranscribe else { return }
        for rec in all where rec.autoPending && rec.transcript.isEmpty && !busy.contains(rec.id) {
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
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "transcribe", expirationHandler: nil)
        defer {
            busy.remove(id)
            progress[id] = nil
            UIApplication.shared.endBackgroundTask(bgTask)
        }

        rec.status = .transcribing
        rec.errorMessage = ""
        save()

        let url = rec.fileURL
        let report: (Double) -> Void = { p in
            Task { @MainActor in Processor.shared.progress[id] = p }
        }
        do {
            let segs = try await Transcription.run(url, engine: engine, progress: report)
            rec.segments = segs
            rec.engineUsed = engine.shortLabel
            rec.status = .done
        } catch {
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
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "organize", expirationHandler: nil)
        defer {
            busy.remove(id)
            UIApplication.shared.endBackgroundTask(bgTask)
        }

        rec.status = .organizing
        rec.errorMessage = ""
        save()
        let oldSummary = rec.summary
        organizeInfo[id] = "正在连接 \(modelName)…"
        defer { organizeInfo[id] = nil }

        let box = StreamBox()
        let onProgress: (String, Int) -> Void = { text, thinking in
            Task { @MainActor in
                let p = Processor.shared
                guard !box.finished, Date().timeIntervalSince(box.lastUI) > 0.5 else { return }
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
            let md = try await Organizer.organize(transcript: rec.transcript,
                                                  segments: rec.segments,
                                                  provider: provider,
                                                  apiKey: key,
                                                  baseURL: AppConfig.llmBaseURL(provider),
                                                  model: modelName,
                                                  style: style,
                                                  onProgress: onProgress)
            box.finished = true
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
            rec.summary = oldSummary
            rec.status = .failed
            rec.errorMessage = "整理失败：\(error.localizedDescription)"
        }
        save()
    }
}
