import AVFoundation
import Foundation
import SherpaOnnx
#if canImport(SherpaOnnxC)
import SherpaOnnxC
#endif

// MARK: - 本地模型文件

enum LocalModels {
    struct File {
        let name: String
        let urls: [String]
        let approxMB: Int
    }

    /// SenseVoice（阿里开源，中/粤/英/日/韩）+ Silero VAD（切分说话片段）
    static let senseVoiceFiles: [File] = [
        File(name: "model.int8.onnx",
             urls: [
                "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx",
                "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx",
             ],
             approxMB: 228),
        File(name: "tokens.txt",
             urls: [
                "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt",
                "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt",
             ],
             approxMB: 1),
        File(name: "silero_vad.onnx",
             urls: [
                "https://hf-mirror.com/csukuangfj/vad/resolve/main/silero_vad.onnx",
                "https://huggingface.co/csukuangfj/vad/resolve/main/silero_vad.onnx",
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
             ],
             approxMB: 2),
    ]

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Models/sensevoice", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    static func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    static var isReady: Bool {
        senseVoiceFiles.allSatisfy { f in
            let attrs = try? FileManager.default.attributesOfItem(atPath: path(f.name))
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            return size > (f.approxMB > 10 ? 100_000_000 : 1_000)
        }
    }

    static var totalMB: Int { senseVoiceFiles.reduce(0) { $0 + $1.approxMB } }

    static func remove() {
        try? FileManager.default.removeItem(at: dir)
    }
}

/// 下载模型，带进度
@MainActor
final class ModelDownloader: NSObject, ObservableObject {
    static let shared = ModelDownloader()

    @Published var downloading = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var error: String?
    @Published var ready = LocalModels.isReady

    private var task: Task<Void, Never>?

    func start() {
        guard !downloading else { return }
        downloading = true
        error = nil
        progress = 0
        task = Task {
            let files = LocalModels.senseVoiceFiles
            let total = Double(LocalModels.totalMB)
            var done = 0.0
            do {
                for f in files {
                    let dest = URL(fileURLWithPath: LocalModels.path(f.name))
                    if FileManager.default.fileExists(atPath: dest.path),
                       ((try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0)
                        > (f.approxMB > 10 ? 100_000_000 : 1_000) {
                        done += Double(f.approxMB)
                        progress = done / total
                        continue
                    }
                    status = "正在下载 \(f.name)"
                    var lastError: Error?
                    var ok = false
                    for u in f.urls {
                        guard let url = URL(string: u) else { continue }
                        do {
                            let base = done
                            try await Self.download(url, to: dest) { frac in
                                Task { @MainActor in
                                    self.progress = (base + frac * Double(f.approxMB)) / total
                                }
                            }
                            ok = true
                            break
                        } catch {
                            lastError = error
                            if Task.isCancelled { throw CancellationError() }
                        }
                    }
                    if !ok { throw lastError ?? VNError("下载失败") }
                    done += Double(f.approxMB)
                    progress = done / total
                }
                status = "下载完成"
                ready = LocalModels.isReady
            } catch is CancellationError {
                status = "已取消"
            } catch {
                self.error = "下载失败：\(error.localizedDescription)。检查网络后重试，断点会接着下。"
            }
            downloading = false
        }
    }

    func cancel() {
        task?.cancel()
    }

    func delete() {
        LocalModels.remove()
        ready = false
        progress = 0
        status = ""
    }

    private static func download(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        let delegate = ProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, resp) = try await session.download(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            try? FileManager.default.removeItem(at: tmp)
            throw VNError("HTTP \(code)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
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

// MARK: - 本地 SenseVoice 转写

enum LocalSenseVoice {
    static func transcribe(url: URL, progress: @escaping (Double) -> Void) async throws -> [TranscriptSegment] {
        guard LocalModels.isReady else {
            throw VNError("还没下载本地模型，到 设置 → 语音转文字 → 本地 SenseVoice 里下载（约 \(LocalModels.totalMB) MB）")
        }
        return try await Task.detached(priority: .userInitiated) {
            try run(url: url, progress: progress)
        }.value
    }

    private static func run(url: URL, progress: @escaping (Double) -> Void) throws -> [TranscriptSegment] {
        let cores = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: LocalModels.path("model.int8.onnx"),
            language: "",
            useInverseTextNormalization: true
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: LocalModels.path("tokens.txt"),
            numThreads: cores,
            debug: 0,
            senseVoice: senseVoice
        )
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80),
            modelConfig: modelConfig
        )
        let recognizer = SherpaOnnxOfflineRecognizer(config: &config)

        let silero = sherpaOnnxSileroVadModelConfig(
            model: LocalModels.path("silero_vad.onnx"),
            threshold: 0.4,
            minSilenceDuration: 0.4,
            minSpeechDuration: 0.25,
            windowSize: 512,
            maxSpeechDuration: 20
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

    /// 去掉 <|zh|><|NEUTRAL|> 这类标签
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
