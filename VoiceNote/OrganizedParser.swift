import AVFoundation
import Foundation

/// 整理结果里的一行，带上它在录音里对应的时间（如果找得到）
struct OrganizedLine: Identifiable {
    let id: Int
    let text: String          // 去掉时间标记后的原始 Markdown 行
    let start: Double?
    let end: Double?

    var hasTime: Bool { start != nil && end != nil }
}

enum OrganizedParser {
    private static let markerRegex = try! NSRegularExpression(
        pattern: #"\s*[\{【\[]\s*(\d+(?:\.\d+)?)\s*[-–~～]\s*(\d+(?:\.\d+)?)\s*[\}】\]]\s*"#)

    /// 去掉 {12.3-20.5} 这类时间标记，用于显示、复制、分享
    static func stripMarkers(_ s: String) -> String {
        let ns = s as NSString
        return markerRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length),
                                                    withTemplate: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    static func parse(_ markdown: String, segments: [TranscriptSegment]) -> [OrganizedLine] {
        let rawLines = markdown.components(separatedBy: "\n")
        var out: [OrganizedLine] = []
        var inBody = false
        var cursor = 0
        let segGrams = segments.map { bigrams($0.text) }

        for (i, raw) in rawLines.enumerated() {
            let ns = raw as NSString
            var start: Double?
            var end: Double?
            if let m = markerRegex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                start = Double(ns.substring(with: m.range(at: 1)))
                end = Double(ns.substring(with: m.range(at: 2)))
            }
            let clean = stripMarkers(raw)
            let trimmed = clean.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#") {
                inBody = trimmed.contains("正文")
            }

            // 没有时间标记时：正文部分按文字相似度去原文里找对应的句子
            if start == nil, inBody, !trimmed.isEmpty, !trimmed.hasPrefix("#"), !segments.isEmpty {
                if let (a, b) = match(line: trimmed, segGrams: segGrams, from: cursor) {
                    start = segments[a].start
                    end = segments[b].end
                    cursor = b + 1
                }
            }
            if let s = start, let e = end, e <= s { end = s + 3 }
            out.append(OrganizedLine(id: i, text: clean, start: start, end: end))
        }
        return out
    }

    private static func match(line: String, segGrams: [Set<String>], from cursor: Int) -> (Int, Int)? {
        var body = line
        // 去掉「甲：」「乙（患者）：」这样的说话人前缀
        if let r = body.range(of: "：") ?? body.range(of: ":"),
           body.distance(from: body.startIndex, to: r.lowerBound) <= 8 {
            body = String(body[r.upperBound...])
        }
        let lineGrams = bigrams(body)
        guard !lineGrams.isEmpty else { return nil }

        // 先在光标后面的窗口里找，找不到再全局找
        let windows = [(cursor, min(segGrams.count, cursor + 25)), (0, segGrams.count)]
        for (lo, hi) in windows where lo < hi {
            var first: Int?
            var last: Int?
            for j in lo..<hi {
                let g = segGrams[j]
                guard !g.isEmpty else { continue }
                let score = Double(g.intersection(lineGrams).count) / Double(g.count)
                if score >= 0.45 {
                    if first == nil { first = j }
                    last = j
                } else if first != nil, j - (last ?? j) > 2 {
                    break
                }
            }
            if let f = first, let l = last { return (f, l) }
        }
        return nil
    }

    static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.filter { !$0.isPunctuation && !$0.isWhitespace && !$0.isSymbol })
        guard chars.count >= 2 else { return Set(chars.map { String($0) }) }
        var set = Set<String>()
        for i in 0..<(chars.count - 1) {
            set.insert(String(chars[i...(i + 1)]))
        }
        return set
    }
}

/// 把录音的某一段剪出来，用于分享
enum ClipExporter {
    static func export(source: URL, start: Double, end: Double, title: String) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw VNError("这个录音没法剪切")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var name = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
        if name.count > 30 { name = String(name.prefix(30)) }
        let out = dir.appendingPathComponent("\(name).m4a")
        try? FileManager.default.removeItem(at: out)

        session.outputURL = out
        session.outputFileType = .m4a
        let s = CMTime(seconds: max(0, start - 0.2), preferredTimescale: 600)
        let e = CMTime(seconds: end + 0.3, preferredTimescale: 600)
        session.timeRange = CMTimeRange(start: s, end: e)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                cont.resume()
            }
        }
        guard session.status == .completed else {
            throw VNError("剪切失败：\(session.error?.localizedDescription ?? "未知错误")")
        }
        return out
    }
}
