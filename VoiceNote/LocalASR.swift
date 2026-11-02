import AVFoundation
import Foundation
import SherpaOnnx
#if canImport(SherpaOnnxC)
import SherpaOnnxC
#endif

// MARK: - 本地模型包

/// 一个要下载的文件：先试模型仓库（ModelScope → hf-mirror → HuggingFace），再试直链
struct ModelFileSpec {
    let local: String          // 在包目录里的相对路径
    let repo: String           // 仓库名，例如 csukuangfj/vad
    let remote: String         // 仓库里的路径
    var direct: [String] = []  // 备用直链（GitHub Release 等）
    var minBytes = 1_000
    var optional = false
    var inArchive = false     // 从压缩包里解出来，不单独下载
}

/// 整个打包下载的模型（GitHub Release 的 .tar.bz2）
struct ModelArchive {
    let urls: [String]
    let stripPrefix: String
    let keep: (String) -> Bool
    let approxMB: Int
}

enum ModelPackage: String, CaseIterable, Identifiable {
    case senseVoice, qwen3, diarization
    var id: String { rawValue }

    var title: String {
        switch self {
        case .senseVoice: return "SenseVoice 识别模型"
        case .qwen3: return "Qwen3-ASR 识别模型"
        case .diarization: return "区分说话人模型"
        }
    }

    var approxMB: Int {
        switch self {
        case .senseVoice: return 231
        case .qwen3: return 940
        case .diarization: return 45
        }
    }

    var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Models/\(rawValue)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    func path(_ local: String) -> String { dir.appendingPathComponent(local).path }

    private static let vad = ModelFileSpec(
        local: "silero_vad.onnx", repo: "csukuangfj/vad", remote: "silero_vad.onnx",
        direct: ["https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"],
        minBytes: 500_000)

    /// 仓库里需要整个目录时，用「目录/」结尾，下载时会列出仓库文件再挑出来
    var files: [ModelFileSpec] {
        switch self {
        case .senseVoice:
            let repo = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
            return [
                ModelFileSpec(local: "model.int8.onnx", repo: repo, remote: "model.int8.onnx", minBytes: 100_000_000),
                ModelFileSpec(local: "tokens.txt", repo: repo, remote: "tokens.txt"),
                Self.vad,
            ]
        case .qwen3:
            return [
                ModelFileSpec(local: "conv_frontend.onnx", repo: "", remote: "", minBytes: 100_000, inArchive: true),
                ModelFileSpec(local: "encoder.int8.onnx", repo: "", remote: "", minBytes: 10_000_000, inArchive: true),
                ModelFileSpec(local: "decoder.int8.onnx", repo: "", remote: "", minBytes: 10_000_000, inArchive: true),
                ModelFileSpec(local: "tokenizer/", repo: "", remote: "", inArchive: true),
                Self.vad,
            ]
        case .diarization:
            return [
                ModelFileSpec(local: "segmentation.onnx", repo: "csukuangfj/sherpa-onnx-pyannote-segmentation-3-0",
                              remote: "model.onnx", minBytes: 1_000_000),
                ModelFileSpec(local: "embedding.onnx", repo: "csukuangfj/speaker-embedding-models",
                              remote: "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx",
                              direct: ["https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"],
                              minBytes: 5_000_000),
            ]
        }
    }

    /// 只能整包下载的模型
    var archive: ModelArchive? {
        switch self {
        case .qwen3:
            let name = "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"
            let gh = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(name).tar.bz2"
            return ModelArchive(
                urls: [gh, "https://ghfast.top/" + gh, "https://gh-proxy.com/" + gh],
                stripPrefix: name + "/",
                keep: { !$0.hasPrefix("test_wavs") && !$0.hasSuffix(".md") && !$0.hasSuffix(".py") },
                approxMB: 900)
        default:
            return nil
        }
    }

    var isReady: Bool {
        files.allSatisfy { f in
            if f.local.hasSuffix("/") {
                let items = (try? FileManager.default.contentsOfDirectory(atPath: path(f.local))) ?? []
                return !items.isEmpty
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: path(f.local)))?[.size] as? NSNumber)?.intValue ?? 0
            return size >= f.minBytes
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: dir)
    }
}

/// 兼容旧代码
enum LocalModels {
    static var isReady: Bool { ModelPackage.senseVoice.isReady }
    static var totalMB: Int { ModelPackage.senseVoice.approxMB }
}

// MARK: - 下载器（多源、断点续传、自动重试）

@MainActor
final class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    @Published var active: ModelPackage?
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var error: [ModelPackage: String] = [:]
    @Published var readyTick = 0

    private var task: Task<Void, Never>?

    func isReady(_ p: ModelPackage) -> Bool { _ = readyTick; return p.isReady }

    func start(_ p: ModelPackage) {
        guard active == nil else { return }
        active = p
        error[p] = nil
        progress = 0
        task = Task {
            do {
                try await Self.fetch(p) { frac, text in
                    Task { @MainActor in
                        self.progress = frac
                        self.status = text
                    }
                }
                status = "下载完成"
            } catch is CancellationError {
                status = "已取消"
            } catch {
                self.error[p] = "下载失败：\(error.localizedDescription)\n已下好的部分会保留，点「下载」会接着下。"
            }
            active = nil
            readyTick += 1
        }
    }

    func cancel() { task?.cancel() }

    func delete(_ p: ModelPackage) {
        p.remove()
        readyTick += 1
    }

    // MARK: 实际下载

    private struct Source {
        let name: String
        let list: (String) -> URL?              // 列出仓库文件的地址
        let file: (String, String) -> URL?      // 某个文件的下载地址
    }

    private static let sources: [Source] = [
        Source(name: "ModelScope",
               list: { URL(string: "https://www.modelscope.cn/api/v1/models/\($0)/repo/files?Recursive=true") },
               file: { URL(string: "https://www.modelscope.cn/models/\($0)/resolve/master/\($1)") }),
        Source(name: "hf-mirror",
               list: { URL(string: "https://hf-mirror.com/api/models/\($0)") },
               file: { URL(string: "https://hf-mirror.com/\($0)/resolve/main/\($1)") }),
        Source(name: "HuggingFace",
               list: { URL(string: "https://huggingface.co/api/models/\($0)") },
               file: { URL(string: "https://huggingface.co/\($0)/resolve/main/\($1)") }),
    ]

    private static func fetch(_ p: ModelPackage,
                              report: @escaping (Double, String) -> Void) async throws {
        // 把目录展开成具体文件
        // 先处理整包（下载 → 解压 → 删掉压缩包）
        if let arc = p.archive, p.files.contains(where: { $0.inArchive && !fileReady(p, $0) }) {
            let tmp = p.dir.appendingPathComponent("_download.tar.bz2")
            var ok = false
            var lastError: Error = VNError("下载失败")
            for u in arc.urls {
                guard let url = URL(string: u) else { continue }
                let host = url.host ?? ""
                do {
                    try await downloadWithRetry(url, to: tmp, minBytes: 50_000_000) { frac in
                        report(frac * 0.85, "正在从 \(host) 下载模型包  \(Int(frac * 100))%")
                    }
                    ok = true
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            if !ok { throw lastError }
            report(0.85, "正在解压…")
            let dest = p.dir
            try await Task.detached(priority: .userInitiated) {
                try TarBz2.extract(tmp, to: dest, stripPrefix: arc.stripPrefix, keep: arc.keep) { f in
                    report(0.85 + f * 0.13, "正在解压  \(Int(f * 100))%")
                }
            }.value
            try? FileManager.default.removeItem(at: tmp)
        }

        var jobs: [(local: String, repo: String, remote: String, direct: [String], minBytes: Int)] = []
        for f in p.files where !f.inArchive {
            if f.remote.hasSuffix("/") {
                let names = try await listDir(repo: f.repo, prefix: f.remote)
                for n in names {
                    let rel = String(n.dropFirst(f.remote.count))
                    jobs.append((f.local + rel, f.repo, n, [], 1))
                }
            } else {
                jobs.append((f.local, f.repo, f.remote, f.direct, f.minBytes))
            }
        }

        let weights = jobs.map { max(1.0, Double($0.minBytes) / 1_000_000) }
        let total = weights.reduce(0, +)
        var done = 0.0

        for (i, job) in jobs.enumerated() {
            try Task.checkCancellation()
            let dest = URL(fileURLWithPath: p.path(job.local))
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.intValue ?? 0
            if size >= job.minBytes {
                done += weights[i]
                report(done / total, "已有 \(job.local)")
                continue
            }
            var urls: [(String, URL)] = sources.compactMap { s in s.file(job.repo, job.remote).map { (s.name, $0) } }
            urls += job.direct.compactMap { u in URL(string: u).map { ("GitHub", $0) } }

            var lastError: Error = VNError("没有可用的下载地址")
            var ok = false
            for (name, url) in urls {
                do {
                    let base = done
                    try await downloadWithRetry(url, to: dest, minBytes: job.minBytes) { frac in
                        report((base + frac * weights[i]) / total,
                               "正在从 \(name) 下载 \(job.local)  \(Int(frac * 100))%")
                    }
                    ok = true
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            if !ok { throw lastError }
            done += weights[i]
            report(done / total, "\(job.local) 完成")
        }
    }

    private static func fileReady(_ p: ModelPackage, _ f: ModelFileSpec) -> Bool {
        if f.local.hasSuffix("/") {
            return !((try? FileManager.default.contentsOfDirectory(atPath: p.path(f.local))) ?? []).isEmpty
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: p.path(f.local)))?[.size] as? NSNumber)?.intValue ?? 0
        return size >= f.minBytes
    }

    /// 列出仓库里某个目录下的文件
    private static func listDir(repo: String, prefix: String) async throws -> [String] {
        for s in sources {
            guard let url = s.list(repo) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            var names: [String] = []
            if let siblings = json["siblings"] as? [[String: Any]] {
                names = siblings.compactMap { $0["rfilename"] as? String }
            } else if let d = json["Data"] as? [String: Any], let files = d["Files"] as? [[String: Any]] {
                names = files.filter { ($0["Type"] as? String) != "tree" }.compactMap { $0["Path"] as? String }
            }
            let hit = names.filter { $0.hasPrefix(prefix) }
            if !hit.isEmpty { return hit }
        }
        // 列不出来时用 Qwen 分词器的常见文件名
        return ["vocab.json", "merges.txt", "tokenizer_config.json"].map { prefix + $0 }
    }

    /// 断点续传：网络断了就带着已下载的部分重试，最多 8 次
    private static func downloadWithRetry(_ url: URL, to dest: URL, minBytes: Int,
                                          progress: @escaping (Double) -> Void) async throws {
        var resume: Data?
        var last: Error = VNError("下载失败")
        for attempt in 0..<8 {
            try Task.checkCancellation()
            let delegate = ProgressDelegate(progress: progress)
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = 3 * 3600
            cfg.waitsForConnectivity = true
            let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (tmp, resp): (URL, URLResponse)
                if let r = resume {
                    (tmp, resp) = try await session.download(resumeFrom: r)
                } else {
                    (tmp, resp) = try await session.download(from: url)
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(code), !(resp.mimeType ?? "").contains("html") else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw VNError("HTTP \(code)")   // 404 之类直接换下一个源
                }
                let size = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.intValue ?? 0
                guard size >= minBytes else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw VNError("文件不完整")
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                return
            } catch let e as URLError {
                if e.code == .cancelled, Task.isCancelled { throw CancellationError() }
                last = e
                resume = e.downloadTaskResumeData
                // 连不上/没权限这类错误不用重试，直接换源
                if [.cannotFindHost, .cannotConnectToHost, .badServerResponse, .userAuthenticationRequired,
                    .secureConnectionFailed, .dnsLookupFailed].contains(e.code), attempt >= 1 {
                    throw e
                }
                try await Task.sleep(nanoseconds: UInt64(1_500_000_000 * Double(attempt + 1)))
            } catch let e as VNError {
                throw e
            }
        }
        throw last
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: (Double) -> Void
    init(progress: @escaping (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

// MARK: - 本地识别（SenseVoice / Qwen3-ASR），VAD 切句

enum LocalRecognizer {
    static func transcribe(url: URL, package: ModelPackage,
                           progress: @escaping (Double) -> Void) async throws -> [TranscriptSegment] {
        guard package.isReady else {
            throw VNError("还没下载\(package.title)，到 设置 → 语音转文字 → 本地模型 里下载（约 \(package.approxMB) MB）")
        }
        return try await Task.detached(priority: .userInitiated) {
            try run(url: url, package: package, progress: progress)
        }.value
    }

    private static func run(url: URL, package p: ModelPackage,
                            progress: @escaping (Double) -> Void) throws -> [TranscriptSegment] {
        let cores = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        let modelConfig: SherpaOnnxOfflineModelConfig
        if p == .qwen3 {
            let q = sherpaOnnxOfflineQwen3ASRModelConfig(
                convFrontend: p.path("conv_frontend.onnx"),
                encoder: p.path("encoder.int8.onnx"),
                decoder: p.path("decoder.int8.onnx"),
                tokenizer: p.path("tokenizer"),
                maxTotalLen: 512,
                maxNewTokens: 256
            )
            modelConfig = sherpaOnnxOfflineModelConfig(tokens: "", numThreads: cores, debug: 0, qwen3Asr: q)
        } else {
            let sv = sherpaOnnxOfflineSenseVoiceModelConfig(
                model: p.path("model.int8.onnx"), language: "", useInverseTextNormalization: true)
            modelConfig = sherpaOnnxOfflineModelConfig(tokens: p.path("tokens.txt"), numThreads: cores,
                                                       debug: 0, senseVoice: sv)
        }
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80),
            modelConfig: modelConfig
        )
        let recognizer = SherpaOnnxOfflineRecognizer(config: &config)

        let silero = sherpaOnnxSileroVadModelConfig(
            model: p.path("silero_vad.onnx"),
            threshold: 0.4,
            minSilenceDuration: 0.4,
            minSpeechDuration: 0.25,
            windowSize: 512,
            maxSpeechDuration: p == .qwen3 ? 15 : 20
        )
        var vadConfig = sherpaOnnxVadModelConfig(sileroVad: silero, numThreads: 1)
        let vad = SherpaOnnxVoiceActivityDetectorWrapper(config: &vadConfig, buffer_size_in_seconds: 60)

        let total = max(1, AudioTools.duration(of: url))
        var out: [TranscriptSegment] = []
        var pending: [Float] = []
        var fed = 0

        func drain() {
            while !vad.isEmpty() {
                let seg = vad.front()
                vad.pop()
                let samples = seg.samples
                let start = Double(seg.start) / 16000
                let dur = Double(samples.count) / 16000
                let text = clean(recognizer.decode(samples: samples, sampleRate: 16000).text)
                if !text.isEmpty {
                    out += SegmentTools.splitEvenly(text, start: start, duration: dur)
                }
            }
        }

        try AudioTools.forEach16kMono(url: url) { chunk in
            pending += chunk
            var i = 0
            while pending.count - i >= 512 {
                vad.acceptWaveform(samples: Array(pending[i..<(i + 512)]))
                i += 512
            }
            pending.removeFirst(i)
            fed += i
            drain()
            progress(min(0.99, Double(fed) / 16000 / total))
        }
        if !pending.isEmpty { vad.acceptWaveform(samples: pending) }
        vad.flush()
        drain()
        progress(1)
        return out
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 区分说话人

/// 给 C 回调传进度用
private final class DiarizeProgress {
    let f: (Double) -> Void
    init(_ f: @escaping (Double) -> Void) { self.f = f }
}

enum Diarizer {
    /// 给每句话标上说话人编号（从 1 开始）。speakers = 0 表示自动判断人数
    static func label(_ segs: [TranscriptSegment], url: URL, speakers: Int,
                      progress: @escaping (Double) -> Void = { _ in }) async throws -> [TranscriptSegment] {
        let p = ModelPackage.diarization
        guard p.isReady, !segs.isEmpty else { return segs }
        return try await Task.detached(priority: .utility) {
            var samples: [Float] = []
            try AudioTools.forEach16kMono(url: url) { samples += $0 }
            guard samples.count > 16000 else { return segs }
            progress(0.02)

            let threads: Int32 = 2   // 多线程更快但手机很烫，长录音宁可慢一点
            var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
                segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                    pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                        model: p.path("segmentation.onnx"), windowShiftRatio: 0.1),
                    numThreads: Int(threads)),
                embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(model: p.path("embedding.onnx"), numThreads: Int(threads)),
                clustering: sherpaOnnxFastClusteringConfig(numClusters: speakers > 0 ? speakers : -1, threshold: 0.8)
            )
            guard let sd = SherpaOnnxCreateOfflineSpeakerDiarization(&config) else { return segs }
            defer { SherpaOnnxDestroyOfflineSpeakerDiarization(sd) }

            let box = DiarizeProgress { progress(0.02 + 0.96 * $0) }
            let arg = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<DiarizeProgress>.fromOpaque(arg).release() }
            let result = samples.withUnsafeBufferPointer { buf in
                SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(
                    sd, buf.baseAddress, Int32(buf.count),
                    { done, total, arg in
                        if let arg, total > 0 {
                            Unmanaged<DiarizeProgress>.fromOpaque(arg).takeUnretainedValue()
                                .f(Double(done) / Double(total))
                        }
                        return 0
                    }, arg)
            }
            guard let result else { return segs }
            defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
            let n = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
            guard n > 0, let sorted = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return segs }
            defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(sorted) }
            let turns: [(start: Float, end: Float, speaker: Int)] = (0..<n).map {
                (sorted[$0].start, sorted[$0].end, Int(sorted[$0].speaker))
            }
            progress(1)
            let assigned: [Int] = segs.map { seg in
                var best = -1
                var bestOverlap = 0.0
                for t in turns {
                    let o = min(seg.end, Double(t.end)) - max(seg.start, Double(t.start))
                    if o > bestOverlap { bestOverlap = o; best = t.speaker }
                }
                if best < 0 {
                    let mid = (seg.start + seg.end) / 2
                    best = turns.min { abs(Double($0.start + $0.end) / 2 - mid) < abs(Double($1.start + $1.end) / 2 - mid) }?.speaker ?? 0
                }
                return best
            }
            // 只按实际出现在句子里的人重新编号：第一个说话的是 1，第二个是 2
            var order: [Int: Int] = [:]
            for sp in assigned where order[sp] == nil { order[sp] = order.count + 1 }
            return zip(segs, assigned).map { seg, sp in
                var s = seg
                s.speaker = order[sp]
                return s
            }
        }.value
    }
}
