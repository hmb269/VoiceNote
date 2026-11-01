import AVFoundation
import CoreMedia
import Foundation
import Speech

private final class OnceBox {
    var done = false
}

// MARK: - 分句工具

enum SegmentTools {
    static let strongBreaks: Set<Character> = ["。", "？", "！", "；", ".", "?", "!", ";"]
    static let weakBreaks: Set<Character> = ["，", ","]

    /// 没有逐字时间时：按标点把一段文字切成句子，时间按字数比例分配
    static func splitEvenly(_ text: String, start: Double, duration: Double) -> [TranscriptSegment] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        var sentences: [String] = []
        var cur = ""
        for ch in t {
            cur.append(ch)
            if strongBreaks.contains(ch) || ch == "\n" {
                let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                cur = ""
            }
        }
        let rest = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { sentences.append(rest) }
        let total = max(1, sentences.reduce(0) { $0 + $1.count })
        var segs: [TranscriptSegment] = []
        var at = start
        for s in sentences {
            let d = duration * Double(s.count) / Double(total)
            segs.append(TranscriptSegment(start: at, end: at + d, text: s))
            at += d
        }
        return segs
    }
}

// MARK: - 苹果本机转写

enum AppleTranscriber {
    static func requestAuth() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    static func transcribe(url: URL, localeID: String,
                           progress: @escaping (Double) -> Void) async throws -> [TranscriptSegment] {
        guard await requestAuth() else {
            throw VNError("没有语音识别权限，请到 设置 → 隐私与安全性 → 语音识别 里打开")
        }

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if let segs = try await ModernTranscriber.transcribe(url: url, localeID: localeID, progress: progress) {
                return segs
            }
        }
        #endif

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            throw VNError("这台手机不支持 \(localeID) 的语音识别")
        }
        guard recognizer.isAvailable else {
            throw VNError("语音识别暂时不可用，检查网络后再试")
        }

        let chunks = try AudioTools.splitToWav(url: url, chunkSeconds: 30)
        defer { AudioTools.cleanup(chunks) }

        var all: [TranscriptSegment] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            all += try await recognize(chunk, with: recognizer)
            progress(Double(i + 1) / Double(chunks.count))
        }
        return all
    }

    private static func recognize(_ chunk: AudioChunk, with recognizer: SFSpeechRecognizer) async throws -> [TranscriptSegment] {
        let request = SFSpeechURLRecognitionRequest(url: chunk.url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        // 不强制本机：苹果服务器识别更准，本机模型只在没网时兜底
        let box = OnceBox()
        let transcription: SFTranscription? = try await withCheckedThrowingContinuation { cont in
            _ = recognizer.recognitionTask(with: request) { result, error in
                if box.done { return }
                if let error {
                    box.done = true
                    let ns = error as NSError
                    // 1110 = 没检测到说话，当作空白
                    if ns.code == 1110 || ns.code == 203 || ns.code == 301 {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                if let result, result.isFinal {
                    box.done = true
                    cont.resume(returning: result.bestTranscription)
                }
            }
        }
        guard let transcription else { return [] }
        return sentences(from: transcription, offset: chunk.start, chunkDuration: chunk.duration)
    }

    /// 用逐词时间把识别结果切成句子
    private static func sentences(from tr: SFTranscription, offset: Double, chunkDuration: Double) -> [TranscriptSegment] {
        let formatted = tr.formattedString as NSString
        let words = tr.segments
        guard !words.isEmpty, formatted.length > 0 else {
            return SegmentTools.splitEvenly(tr.formattedString, start: offset, duration: chunkDuration)
        }
        var out: [TranscriptSegment] = []
        var sStart: Double?
        var textStart = 0
        for (i, w) in words.enumerated() {
            if sStart == nil {
                sStart = w.timestamp
                textStart = w.substringRange.location
            }
            var endLoc = w.substringRange.location + w.substringRange.length
            var strong = false
            var weak = false
            while endLoc < formatted.length {
                let ch = Character(formatted.substring(with: NSRange(location: endLoc, length: 1)))
                if SegmentTools.strongBreaks.contains(ch) { strong = true; endLoc += 1 }
                else if SegmentTools.weakBreaks.contains(ch) { weak = true; endLoc += 1 }
                else { break }
            }
            let wEnd = w.timestamp + w.duration
            let longEnough = wEnd - (sStart ?? 0) > 6
            if strong || (weak && longEnough) || i == words.count - 1 {
                let len = max(0, min(endLoc, formatted.length) - textStart)
                let text = formatted.substring(with: NSRange(location: textStart, length: len))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    out.append(TranscriptSegment(start: offset + (sStart ?? 0), end: offset + wEnd, text: text))
                }
                sStart = nil
                textStart = endLoc
            }
        }
        return out
    }
}

// MARK: - iOS 26+ 新版长音频识别（SpeechAnalyzer）

#if compiler(>=6.2)
@available(iOS 26.0, *)
enum ModernTranscriber {
    /// 返回 nil 表示这个语言新引擎不支持，交给旧引擎
    static func transcribe(url: URL, localeID: String,
                           progress: @escaping (Double) -> Void) async throws -> [TranscriptSegment]? {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            return nil
        }
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            return nil
        }

        let file = try AVAudioFile(forReading: url)
        let total = max(1, Double(file.length) / file.processingFormat.sampleRate)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () -> [TranscriptSegment] in
            var segs: [TranscriptSegment] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let t = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let s = result.range.start.seconds
                let e = result.range.end.seconds
                guard !t.isEmpty, s.isFinite, e.isFinite else { continue }
                // 一个结果可能很长，按句号再切细，时间按字数分
                segs += SegmentTools.splitEvenly(t, start: s, duration: max(0.1, e - s))
                progress(min(0.99, e / total))
            }
            return segs
        }

        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let segs = try await collector.value
        progress(1)
        return segs
    }
}
#endif

// MARK: - 阿里云百炼 Qwen-ASR

enum AliyunTranscriber {
    static func transcribe(url: URL, apiKey: String, baseURL: String, model: String,
                           language: String,
                           progress: @escaping (Double) -> Void) async throws -> [TranscriptSegment] {
        // 每 30 秒一段，方便点句子定位；计费按时长，分段不会多花钱
        let chunks = try AudioTools.splitToWav(url: url, chunkSeconds: 30)
        defer { AudioTools.cleanup(chunks) }

        var all: [TranscriptSegment] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let data = try Data(contentsOf: chunk.url)
            let dataURI = "data:audio/wav;base64," + data.base64EncodedString()
            var asrOptions: [String: Any] = ["enable_itn": true]
            if language != "auto" { asrOptions["language"] = language }
            let body: [String: Any] = [
                "model": model,
                "messages": [[
                    "role": "user",
                    "content": [[
                        "type": "input_audio",
                        "input_audio": ["data": dataURI],
                    ]],
                ]],
                "stream": false,
                "asr_options": asrOptions,
            ]
            let text = try await OpenAIClient.chat(baseURL: baseURL, apiKey: apiKey, body: body, timeout: 120)
            all += SegmentTools.splitEvenly(text, start: chunk.start, duration: chunk.duration)
            progress(Double(i + 1) / Double(chunks.count))
        }
        return all
    }
}

// MARK: - OpenAI 兼容接口

enum OpenAIClient {
    static func chat(baseURL: String, apiKey: String, body: [String: Any],
                     timeout: TimeInterval) async throws -> String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
        }
        guard let url = URL(string: base + "/chat/completions"), !base.isEmpty else {
            throw VNError("接口地址不对：\(baseURL)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let raw = String(data: data, encoding: .utf8) ?? ""

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw VNError("服务器返回异常（HTTP \(code)）：\(String(raw.prefix(300)))")
        }
        if !(200..<300).contains(code) {
            var msg = String(raw.prefix(300))
            if let err = json["error"] as? [String: Any], let m = err["message"] as? String {
                msg = m
            } else if let m = json["message"] as? String {
                msg = m
            }
            throw VNError("请求失败（HTTP \(code)）：\(msg)")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw VNError("返回内容看不懂：\(String(raw.prefix(300)))")
        }
        if let s = message["content"] as? String { return s }
        if let arr = message["content"] as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }
}

// MARK: - AI 整理

enum Organizer {
    static let systemPrompt = """
    你是录音整理助手。用户会给你一段语音自动转写的原文，里面可能有同音错字、口头禅、重复、断句混乱，也可能夹杂粤语或方言。
    请整理成下面的 Markdown 格式，只输出这些内容，不要多余的解释：

    # 标题（不超过15个字，概括主题）

    ## 摘要
    用3到5句话说清楚这段录音讲了什么。

    ## 要点
    - 要点1
    - 要点2

    ## 待办
    - [ ] 需要做的事（谁、什么时候，如果原文有提到）
    没有待办就写“无”。

    ## 整理后的正文
    去掉口头禅和无意义的重复，修正明显的同音错字，补上标点，合理分段，保持原意。
    如果能看出是多人对话，用“甲：”“乙：”区分说话人。不要编造原文没有的内容。
    """

    static func organize(transcript: String, provider: LLMProvider, apiKey: String,
                         baseURL: String, model: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "下面是录音转写原文：\n\n" + transcript],
            ],
            "temperature": 0.3,
            "stream": false,
        ]
        _ = provider // 新版 GLM Flash 不支持关闭思考，不再传 thinking 参数
        let out = try await OpenAIClient.chat(baseURL: baseURL, apiKey: apiKey, body: body, timeout: 600)
        return clean(out)
    }

    static func test(provider: LLMProvider, apiKey: String, baseURL: String, model: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "回复“连接成功”四个字"]],
            "stream": false,
        ]
        return clean(try await OpenAIClient.chat(baseURL: baseURL, apiKey: apiKey, body: body, timeout: 60))
    }

    static func clean(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "</think>") {
            t = String(t[r.upperBound...])
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            var lines = t.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
                lines.removeLast()
            }
            t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    static func extractTitle(_ markdown: String) -> String? {
        for line in markdown.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("# ") {
                let title = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : String(title.prefix(30))
            }
        }
        return nil
    }
}
