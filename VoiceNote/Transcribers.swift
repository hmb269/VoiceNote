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

        let ck = ChunkCache.key(url, "aliyun-\(model)-\(language)-30")
        var cached = ChunkCache.load(ck)
        var all: [TranscriptSegment] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            if let c = cached[i] {
                all += c
                progress(Double(i + 1) / Double(chunks.count))
                continue
            }
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
            let text = try await ChunkCache.retry { try await OpenAIClient.chat(baseURL: baseURL, apiKey: apiKey, body: body, timeout: 120) }
            let segs = SegmentTools.splitEvenly(text, start: chunk.start, duration: chunk.duration)
            all += segs
            cached[i] = segs
            ChunkCache.save(ck, cached)
            progress(Double(i + 1) / Double(chunks.count))
        }
        return all
    }
}

// MARK: - OpenAI 兼容的转写接口（硅基流动、智谱 GLM-ASR、自定义 Whisper 等）

enum FileTranscriber {
    static func transcribe(url: URL, endpoint: String, apiKey: String, model: String,
                           chunkSeconds: Double, name: String, extra: [String: String] = [:],
                           progress: @escaping (Double) -> Void) async throws -> [TranscriptSegment] {
        var ep = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while ep.hasSuffix("/") { ep.removeLast() }
        if !ep.hasSuffix("/audio/transcriptions") { ep += "/audio/transcriptions" }
        guard let endpointURL = URL(string: ep) else { throw VNError("\(name)的接口地址不对") }

        let chunks = try AudioTools.splitToWav(url: url, chunkSeconds: chunkSeconds)
        defer { AudioTools.cleanup(chunks) }

        let ck = ChunkCache.key(url, "\(name)-\(model)-\(Int(chunkSeconds))")
        var cached = ChunkCache.load(ck)
        var all: [TranscriptSegment] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            if let c = cached[i] {
                all += c
                progress(Double(i + 1) / Double(chunks.count))
                continue
            }
            let boundary = "VN-\(UUID().uuidString)"
            var body = Data()
            func field(_ k: String, _ v: String) {
                body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
            }
            field("model", model)
            for (k, v) in extra { field(k, v) }
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(try Data(contentsOf: chunk.url))
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

            var req = URLRequest(url: endpointURL)
            req.httpMethod = "POST"
            req.timeoutInterval = 120
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.httpBody = body

            let (data, resp) = try await ChunkCache.retry { try await URLSession.shared.data(for: req) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            var text: String?
            if let t = json?["text"] as? String { text = t }
            if text == nil, let choices = json?["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any] {
                text = msg["content"] as? String
            }
            guard (200..<300).contains(code), var t = text else {
                var msg = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
                if let err = json?["error"] as? [String: Any], let m = err["message"] as? String { msg = m }
                else if let m = json?["message"] as? String { msg = m }
                throw VNError("\(name)转写失败（HTTP \(code)）：\(msg)")
            }
            // SenseVoice 会带 <|zh|><|NEUTRAL|> 这类标签
            t = t.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            t = WhisperFilter.clean(t)
            let segs = SegmentTools.splitEvenly(t, start: chunk.start, duration: chunk.duration)
            all += segs
            cached[i] = segs
            ChunkCache.save(ck, cached)
            progress(Double(i + 1) / Double(chunks.count))
        }
        return all
    }
}

/// 去掉 Whisper 在静音处常见的「幻听」句子
enum WhisperFilter {
    /// 给 Whisper 的提示要写成「例句」而不是指令，否则它会把指令原样吐回来
    static let prompt = "嗯，好的。那我们开始吧，今天主要说一下这个事情。"

    static let junk = ["请使用简体中文", "并加上标点符号", "以下是普通话的句子", prompt, "那我们开始吧", "字幕由", "请不吝点赞", "订阅", "打赏支持", "明镜与点点", "Amara.org", "字幕志愿者", "感谢观看", "謝謝觀看"]

    static func clean(_ raw: String) -> String {
        // 繁体转简体
        let s = raw.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? raw
        let parts = s.components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
        if parts.contains(where: { p in junk.contains { p.contains($0) } }) {
            return parts.filter { p in !junk.contains { p.contains($0) } }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "。")
        }
        return s
    }
}

/// 根据设置里选的转写方式调用对应的服务
enum Transcription {
    static func run(_ url: URL, engine: ASREngine, progress: @escaping (Double) -> Void) async throws -> [TranscriptSegment] {
        let segs = try await recognize(url, engine: engine) { progress($0 * (AppConfig.diarize ? 0.85 : 1)) }
        guard AppConfig.diarize, ModelPackage.diarization.isReady else { return segs }
        let labeled = (try? await Diarizer.label(segs, url: url, speakers: AppConfig.speakerCount)) ?? segs
        progress(1)
        return labeled
    }

    private static func recognize(_ url: URL, engine: ASREngine, progress: @escaping (Double) -> Void) async throws -> [TranscriptSegment] {
        func key(_ k: KeyName) throws -> String {
            guard let v = Keychain.get(k) else {
                throw VNError("还没填\(engine.title)的 API Key，到 设置 → 语音转文字 里填")
            }
            return v
        }
        switch engine {
        case .apple:
            return try await AppleTranscriber.transcribe(url: url, localeID: AppConfig.appleLocale, progress: progress)
        case .local:
            return try await LocalRecognizer.transcribe(url: url, package: .senseVoice, progress: progress)
        case .localQwen:
            return try await LocalRecognizer.transcribe(url: url, package: .qwen3, progress: progress)
        case .groq:
            return try await FileTranscriber.transcribe(
                url: url, endpoint: "https://api.groq.com/openai/v1",
                apiKey: try key(.groq), model: AppConfig.groqModel,
                chunkSeconds: 60, name: "Groq",
                extra: ["language": "zh", "temperature": "0",
                        "prompt": WhisperFilter.prompt],
                progress: progress)
        case .aliyun:
            return try await AliyunTranscriber.transcribe(url: url, apiKey: try key(.aliyun),
                                                          baseURL: AppConfig.aliyunBaseURL,
                                                          model: AppConfig.aliyunModel,
                                                          language: AppConfig.aliyunLanguage,
                                                          progress: progress)
        case .siliconflow:
            return try await FileTranscriber.transcribe(url: url, endpoint: "https://api.siliconflow.cn/v1",
                                                        apiKey: try key(.siliconflow), model: AppConfig.siliconModel,
                                                        chunkSeconds: 60, name: "硅基流动", progress: progress)
        case .zhipu:
            return try await FileTranscriber.transcribe(url: url, endpoint: "https://open.bigmodel.cn/api/paas/v4",
                                                        apiKey: try key(.zhipu), model: AppConfig.zhipuASRModel,
                                                        chunkSeconds: 25, name: "智谱", progress: progress)
        case .custom:
            return try await FileTranscriber.transcribe(url: url, endpoint: AppConfig.customASRBase,
                                                        apiKey: try key(.asrCustom), model: AppConfig.customASRModel,
                                                        chunkSeconds: 60, name: "自定义接口", progress: progress)
        }
    }
}

// MARK: - OpenAI 兼容接口

enum OpenAIClient {
    /// 拉取服务商的模型列表（GET /models）
    static func listModels(baseURL: String, apiKey: String) async throws -> [String] {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/models") else { throw VNError("接口地址不对") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            throw VNError("这家服务商不支持拉取模型列表（HTTP \(code)），可以手动填模型名")
        }
        return arr.compactMap { $0["id"] as? String }.sorted()
    }

    /// 流式请求：边生成边回调。onDelta(正文累计, 思考字数)
    static func chatStream(baseURL: String, apiKey: String, body: [String: Any], timeout: TimeInterval,
                           onDelta: @escaping (String, Int) -> Void) async throws -> String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
        }
        guard let url = URL(string: base + "/chat/completions"), !base.isEmpty else {
            throw VNError("接口地址不对：\(baseURL)")
        }
        var b = body
        b["stream"] = true
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: b)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) {
            var raw = ""
            for try await line in bytes.lines { raw += line; if raw.count > 2000 { break } }
            var msg = String(raw.prefix(300))
            if let d = raw.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                if let err = json["error"] as? [String: Any], let m = err["message"] as? String { msg = m }
                else if let m = json["message"] as? String { msg = m }
            }
            throw VNError("请求失败（HTTP \(code)）：\(msg)")
        }

        var content = ""
        var reasoning = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            if let err = json["error"] as? [String: Any], let m = err["message"] as? String {
                throw VNError("生成中断：\(m)")
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }
            if let r = delta["reasoning_content"] as? String { reasoning += r.count }
            if let c = delta["content"] as? String, !c.isEmpty {
                content += c
            }
            onDelta(content, reasoning)
        }
        return content
    }

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
    private static let common = """
    格式说明：〔 〕里是要你填的内容，输出时不要保留〔 〕和里面的说明文字。第一行是「# 」加上不超过15个字的标题，标题必须和「# 」写在同一行。
    你是录音整理助手。用户会给你一段语音自动转写的原文，里面可能有同音错字、口头禅、重复、断句混乱，也可能夹杂粤语或方言。
    根据上下文修正明显的同音错字和专有名词，不要编造原文没有的内容。只输出下面格式的 Markdown，不要多余的解释。
    """

    private static let speakerRule = """
    关于说话人：如果原文每句前面有「说话人1：」「说话人2：」，这是声纹识别分出来的不同的人（同一个编号就是同一个人，但偶尔会分错）。
    整理时用这个编号区分发言人，能从内容判断身份的写成「说话人1（医生）：」，判断不出就保留「说话人1：」。不要再用甲乙。
    """

    private static let timeRule = """
    关于时间标记：如果原文每行开头有 [起-止]（单位是秒），说明这句在录音里的位置。
    - 列表里的每一条（要点、决议、待办、议题下的观点等）结尾写上 {起-止}，指向原文里出处的那几句，例如：- 下周三前交方案 {42.0-51.5}
    - 摘要/概要和「整理后的正文」不要写时间标记，正文尽量保留原话的用词和顺序。
    - 原文没有时间标记就都不用写。
    """

    /// 很短的录音（几句话）只要标题和一句话摘要，避免模型硬凑出一大篇
    static let shortPrompt = """
    用户给你一段很短的语音转写，只有一两句话。可能有同音错字，按上下文修正，不要编造。
    只输出下面三部分，不要多余解释，〔 〕里是要你填的内容，输出时不要保留〔 〕：

    # 〔不超过12个字的标题〕

    ## 摘要
    〔一句话说明这段话的意思〕

    ## 整理后的正文
    〔修正错字、补好标点后的原话，不要扩写〕
    """

    static func systemPrompt(_ style: OrganizeStyle) -> String {
        let format: String
        switch style {
        case .general:
            format = """
            # 〔标题〕

            ## 摘要
            用3到5句话说清楚这段录音讲了什么。

            ## 要点
            - 要点

            ## 待办
            - [ ] 需要做的事（谁、什么时候，如果原文有提到）
            没有待办就写“无”。

            ## 整理后的正文
            去掉口头禅和无意义的重复，补上标点，合理分段，保持原意。
            如果能看出是多人对话，用“甲：”“乙：”区分说话人；能从内容判断身份的，写成“甲（经理）：”。
            """
        case .meeting:
            format = """
            # 〔会议主题〕

            ## 会议概要
            - 参会人：能从内容判断出的人名或角色，判断不出就写“未提及”
            - 时间/地点：原文提到才写
            - 一段话（3到5句）概括这次会议讨论了什么、得出了什么结论。

            ## 议题与讨论
            ### 议题一：简短名称
            - 各方的主要观点、理由和数据（谁说的写清楚）
            ### 议题二：……
            （按讨论的先后顺序列出全部议题）

            ## 决议
            - 会上明确达成的结论或决定
            没有就写“无”。

            ## 待办
            - [ ] 事项 —— 负责人 —— 截止时间（没提到就写“未定”）
            没有就写“无”。

            ## 待确认 / 分歧
            - 还没定下来的问题、意见不一致的地方、需要会后确认的事项
            没有就写“无”。

            ## 整理后的正文
            按发言顺序整理成会议记录：去掉寒暄、口头禅和重复，补标点，合理分段。
            用“甲：”“乙：”区分发言人，能判断身份或姓名的写成“甲（张经理）：”。
            """
        case .conversation:
            format = """
            # 〔标题：谁和谁聊了什么〕

            ## 摘要
            3到5句话：谈话双方是谁（能判断的话）、主要聊了什么、结果如何。

            ## 关键信息
            - 对方提出的要求、给出的承诺、提到的金额、日期、电话、地址等具体信息

            ## 待办
            - [ ] 需要跟进的事（谁、什么时候）
            没有就写“无”。

            ## 整理后的正文
            按对话顺序整理，用“甲：”“乙：”区分说话人，能判断身份的写成“甲（医生）：”。去掉口头禅和重复，保持原意。
            """
        case .lecture:
            format = """
            # 〔课程或讲座主题〕

            ## 摘要
            3到5句话概括主要内容。

            ## 知识点
            - 按讲解顺序列出核心概念、结论、方法，每条一句话说清楚

            ## 重点与例子
            - 讲者特别强调的地方、举的例子、提到的数据或公式

            ## 待办
            - [ ] 布置的作业、要准备的材料、提到的截止时间
            没有就写“无”。

            ## 整理后的正文
            整理成通顺的讲稿：去掉口头禅和重复，补标点，按主题分段。
            """
        }
        return common + "\n\n" + format + "\n\n" + timeRule + "\n\n" + speakerRule
    }

    static func organize(transcript: String, segments: [TranscriptSegment], provider: LLMProvider,
                         apiKey: String, baseURL: String, model: String,
                         style: OrganizeStyle = AppConfig.organizeStyle,
                         onProgress: ((String, Int) -> Void)? = nil) async throws -> String {
        let source: String
        if segments.isEmpty {
            source = transcript
        } else {
            source = segments.map { s in
                let who = s.speaker.map { "说话人\($0)：" } ?? ""
                return "[\(fmt(s.start))-\(fmt(s.end))] \(who)\(s.text)"
            }.joined(separator: "\n")
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": transcript.count < 120 ? shortPrompt : systemPrompt(style)],
                ["role": "user", "content": "下面是录音转写原文：\n\n" + source],
            ],
            "temperature": 0.3,
            "stream": false,
        ]
        _ = provider // 新版 GLM Flash 不支持关闭思考，不再传 thinking 参数
        // 智谱的 Flash 模型总是先「思考」，把思考强度调低能快很多；不支持这个参数时自动去掉重试
        var fast = body
        if provider == .zhipu {
            fast["reasoning_effort"] = "low"
        }
        let progress = onProgress ?? { _, _ in }
        do {
            let out = try await OpenAIClient.chatStream(baseURL: baseURL, apiKey: apiKey, body: fast,
                                                        timeout: 900, onDelta: progress)
            return clean(out)
        } catch let e as VNError where provider == .zhipu && e.message.contains("HTTP 400") {
            let out = try await OpenAIClient.chatStream(baseURL: baseURL, apiKey: apiKey, body: body,
                                                        timeout: 900, onDelta: progress)
            return clean(out)
        }
    }

    private static func fmt(_ t: Double) -> String {
        String(format: "%.1f", t)
    }

    static let highlightPrompt = """
    下面是用户从一段录音里挑出来的重点句，按时间顺序排列，可能有重复或口语。
    请归纳成下面的 Markdown，只输出这些内容：

    ## 一句话总结
    用一句话说清楚这些重点讲的是什么。

    ## 核心要点
    - 合并重复的意思，按重要程度列 3 到 7 条，每条一句话

    ## 需要跟进
    - [ ] 这些重点里提到的要做的事（谁、什么时候）
    没有就写“无”。
    """

    static func summarizeHighlights(_ items: [String], provider: LLMProvider, apiKey: String,
                                    baseURL: String, model: String,
                                    onProgress: ((String, Int) -> Void)? = nil) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": highlightPrompt],
                ["role": "user", "content": items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")],
            ],
            "temperature": 0.3,
        ]
        let out = try await OpenAIClient.chatStream(baseURL: baseURL, apiKey: apiKey, body: body,
                                                    timeout: 300, onDelta: onProgress ?? { _, _ in })
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
        let lines = markdown.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for (i, l) in lines.enumerated() where l.hasPrefix("# ") {
            var title = OrganizedParser.stripMarkers(String(l.dropFirst(2))).trimmingCharacters(in: .whitespaces)
            title = title.replacingOccurrences(of: "〔", with: "").replacingOccurrences(of: "〕", with: "")
            if isPlaceholder(title) {
                // 模型把说明照抄了，真正的标题在下一行
                if let next = lines[(i + 1)...].first(where: { !$0.isEmpty }), !next.hasPrefix("#") {
                    title = next
                } else {
                    return nil
                }
            }
            return title.isEmpty ? nil : String(title.prefix(30))
        }
        return nil
    }

    static func isPlaceholder(_ t: String) -> Bool {
        t.contains("不超过") || t.contains("个字") || t == "标题" || t == "会议主题" || t.hasPrefix("标题（")
    }
}

/// 云端分段转写的断点：每段转完就存，App 被系统关掉后从断点继续
enum ChunkCache {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("asr-progress", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func key(_ url: URL, _ tag: String) -> String {
        let safe = tag.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return url.lastPathComponent + "--" + String(safe)
    }

    static func load(_ key: String) -> [Int: [TranscriptSegment]] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(key + ".json")),
              let m = try? JSONDecoder().decode([String: [TranscriptSegment]].self, from: d) else { return [:] }
        return Dictionary(uniqueKeysWithValues: m.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    static func save(_ key: String, _ map: [Int: [TranscriptSegment]]) {
        let m = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        if let d = try? JSONEncoder().encode(m) {
            try? d.write(to: dir.appendingPathComponent(key + ".json"), options: .atomic)
        }
    }

    /// 转写成功后清掉这条录音的断点
    static func clear(_ url: URL) {
        let prefix = url.lastPathComponent + "--"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    /// 网络抖一下（比如切后台、锁屏）自动重试，最多 3 次
    static func retry<T>(_ work: () async throws -> T) async throws -> T {
        var last: Error?
        for attempt in 0..<3 {
            do { return try await work() } catch {
                if error is CancellationError { throw error }
                if let e = error as? VNError, !e.message.contains("HTTP 5"), !e.message.contains("HTTP 429") { throw error }
                last = error
                try await Task.sleep(nanoseconds: UInt64(2 + attempt * 3) * 1_000_000_000)
            }
        }
        throw last!
    }
}
