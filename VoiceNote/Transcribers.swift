import Foundation
import Speech

private final class OnceBox {
    var done = false
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
                           progress: @escaping (Double) -> Void) async throws -> String {
        guard await requestAuth() else {
            throw VNError("没有语音识别权限，请到 设置 → 隐私与安全性 → 语音识别 里打开")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            throw VNError("这台手机不支持 \(localeID) 的语音识别")
        }
        guard recognizer.isAvailable else {
            throw VNError("语音识别暂时不可用，稍后再试")
        }

        let chunks = try AudioTools.splitToWav(url: url, chunkSeconds: 50)
        defer { AudioTools.cleanup(chunks) }

        var parts: [String] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let text = try await recognize(chunk, with: recognizer)
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append(t) }
            progress(Double(i + 1) / Double(chunks.count))
        }
        return parts.joined(separator: "\n")
    }

    private static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let box = OnceBox()
        return try await withCheckedThrowingContinuation { cont in
            _ = recognizer.recognitionTask(with: request) { result, error in
                if box.done { return }
                if let error {
                    box.done = true
                    let ns = error as NSError
                    // 1110 = 没检测到说话，当作空白
                    if ns.code == 1110 || ns.code == 203 || ns.code == 301 {
                        cont.resume(returning: "")
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                if let result, result.isFinal {
                    box.done = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}

// MARK: - 阿里云百炼 Qwen-ASR

enum AliyunTranscriber {
    static func transcribe(url: URL, apiKey: String, baseURL: String, model: String,
                           language: String,
                           progress: @escaping (Double) -> Void) async throws -> String {
        // 每段 2 分钟的 16k WAV 约 3.8MB，base64 后约 5MB，在 10MB 限制内
        let chunks = try AudioTools.splitToWav(url: url, chunkSeconds: 120)
        defer { AudioTools.cleanup(chunks) }

        var parts: [String] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let data = try Data(contentsOf: chunk)
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
            let text = try await OpenAIClient.chat(baseURL: baseURL, apiKey: apiKey, body: body, timeout: 180)
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append(t) }
            progress(Double(i + 1) / Double(chunks.count))
        }
        return parts.joined(separator: "\n")
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
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "下面是录音转写原文：\n\n" + transcript],
            ],
            "temperature": 0.3,
            "stream": false,
        ]
        if provider == .zhipu {
            body["thinking"] = ["type": "disabled"]
        }
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
