import Foundation
import SwiftData
import UIKit

/// 负责：新录音入库、转写、AI 整理。所有任务排队一个一个跑。
@MainActor
final class Processor: ObservableObject {
    static let shared = Processor()

    var container: ModelContainer?
    @Published var progress: [UUID: Double] = [:]
    @Published var busy: Set<UUID> = []
    @Published var lastError: String?

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

    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        let dest = Storage.recordingsDir.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            lastError = "导入失败：\(error.localizedDescription)"
            return
        }
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        ingest(fileName: name, source: .imported, createdAt: created,
               title: url.deletingPathExtension().lastPathComponent)
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
        if rec.status == .done, rec.hasSpeech, AppConfig.autoOrganize,
           Keychain.get(AppConfig.llmProvider.keyName) != nil {
            await organize(rec)
        }
    }

    // MARK: 手动操作（从详情页点按钮）

    func requestTranscribe(_ rec: Recording, engine: ASREngine) {
        enqueue { await self.transcribe(rec, engine: engine) }
    }

    func requestOrganize(_ rec: Recording) {
        enqueue { await self.organize(rec) }
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
            let segs: [TranscriptSegment]
            switch engine {
            case .apple:
                segs = try await AppleTranscriber.transcribe(url: url, localeID: AppConfig.appleLocale,
                                                             progress: report)
            case .aliyun:
                guard let key = Keychain.get(.aliyun) else {
                    throw VNError("还没填阿里云百炼的 API Key，到设置里填")
                }
                segs = try await AliyunTranscriber.transcribe(url: url, apiKey: key,
                                                              baseURL: AppConfig.aliyunBaseURL,
                                                              model: AppConfig.aliyunModel,
                                                              language: AppConfig.aliyunLanguage,
                                                              progress: report)
            }
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

    private func organize(_ rec: Recording) async {
        let id = rec.id
        guard !busy.contains(id) else { return }
        guard rec.hasSpeech else {
            rec.errorMessage = "还没有可整理的文字，先转写"
            return
        }
        let provider = AppConfig.llmProvider
        guard let key = Keychain.get(provider.keyName) else {
            rec.errorMessage = "还没填 \(provider.label) 的 API Key，到设置里填"
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

        do {
            let md = try await Organizer.organize(transcript: rec.transcript,
                                                  segments: rec.segments,
                                                  provider: provider,
                                                  apiKey: key,
                                                  baseURL: AppConfig.llmBaseURL(provider),
                                                  model: AppConfig.llmModel(provider))
            rec.summary = md
            if let t = Organizer.extractTitle(md) { rec.title = t }
            rec.status = .done
        } catch {
            rec.status = .failed
            rec.errorMessage = "整理失败：\(error.localizedDescription)"
        }
        save()
    }
}
