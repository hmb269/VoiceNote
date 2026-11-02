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
        struct Item {
            let id: Int
            let text: String
            var start: Double?
            var end: Double?
            let isBody: Bool
        }
        var items: [Item] = []
        var inBody = false
        for (i, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let ns = raw as NSString
            var start: Double?
            var end: Double?
            if let m = markerRegex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                start = Double(ns.substring(with: m.range(at: 1)))
                end = Double(ns.substring(with: m.range(at: 2)))
            }
            let clean = stripMarkers(raw)
            let trimmed = clean.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { inBody = trimmed.contains("正文") }
            let isBody = inBody && !trimmed.isEmpty && !trimmed.hasPrefix("#")
            items.append(Item(id: i, text: clean, start: start, end: end, isBody: isBody))
        }

        // 正文：和原文逐字对齐，每一行都算出对应的录音时间
        let bodyIdx = items.indices.filter { items[$0].isBody }
        if !segments.isEmpty, !bodyIdx.isEmpty {
            let spans = align(lines: bodyIdx.map { spoken(items[$0].text) }, segments: segments)
            for (k, idx) in bodyIdx.enumerated() {
                if let sp = spans[k] {
                    items[idx].start = sp.0
                    items[idx].end = sp.1
                }
            }
        }

        return items.map { it in
            var e = it.end
            if let s = it.start, let ee = e, ee <= s { e = s + 2 }
            return OrganizedLine(id: it.id, text: it.text, start: it.start, end: e)
        }
    }

    private static func keep(_ c: Character) -> Bool {
        !c.isPunctuation && !c.isWhitespace && !c.isSymbol
    }

    /// 去掉 Markdown 符号和「甲（医生）：」这样的说话人前缀，只留说的话
    private static func spoken(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        for p in ["- [ ] ", "- [x] ", "- ", "* "] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count))
            break
        }
        if let r = t.range(of: "：") ?? t.range(of: ":"),
           t.distance(from: t.startIndex, to: r.lowerBound) <= 10 {
            t = String(t[r.upperBound...])
        }
        return t.replacingOccurrences(of: "**", with: "")
    }

    /// 把整理后的每一行和原文按字对齐（找共同的两字词，取最长递增链），返回每行的起止时间
    private static func align(lines: [String], segments: [TranscriptSegment]) -> [(Double, Double)?] {
        // 原文字符流，每个字按所在句子的时长平均分配时间
        var sChars: [Character] = []
        var sStart: [Double] = []
        var sEnd: [Double] = []
        for seg in segments {
            let cs = Array(seg.text.filter(keep))
            guard !cs.isEmpty else { continue }
            let d = max(0.05, seg.end - seg.start) / Double(cs.count)
            for k in 0..<cs.count {
                sChars.append(cs[k])
                sStart.append(seg.start + Double(k) * d)
                sEnd.append(seg.start + Double(k + 1) * d)
            }
        }
        var lChars: [Character] = []
        var ranges: [Range<Int>] = []
        for l in lines {
            let a = lChars.count
            lChars += Array(l.filter(keep))
            ranges.append(a..<lChars.count)
        }
        guard sChars.count >= 2, lChars.count >= 2 else { return lines.map { _ in nil } }

        var index: [String: [Int]] = [:]
        for p in 0..<(sChars.count - 1) {
            index[String([sChars[p], sChars[p + 1]]), default: []].append(p)
        }
        // (整理稿位置, 原文位置)，同一个整理稿位置按原文位置倒序，保证链上每个位置只用一次
        var pairs: [(Int, Int)] = []
        for i in 0..<(lChars.count - 1) {
            guard let ps = index[String([lChars[i], lChars[i + 1]])], ps.count <= 40 else { continue }
            for p in ps.reversed() { pairs.append((i, p)) }
        }
        var map: [Int: Int] = [:]
        for (i, p) in longestChain(pairs) {
            map[i] = p
            if map[i + 1] == nil { map[i + 1] = p + 1 }
        }

        // 每行：用行内第一个和最后一个对上的字，向两端推出原文范围
        var spans: [(Int, Int)?] = ranges.map { r in
            let anchors = r.compactMap { i in map[i].map { (i, $0) } }
            guard let f = anchors.first, let l = anchors.last else { return nil }
            let sp = max(0, f.1 - (f.0 - r.lowerBound))
            let ep = min(sChars.count - 1, l.1 + (r.upperBound - 1 - l.0))
            return (sp, max(sp, ep))
        }
        // 保证前后不重叠
        var lastEnd = -1
        for k in spans.indices {
            guard var s = spans[k] else { continue }
            if s.0 <= lastEnd { s.0 = min(lastEnd + 1, s.1) }
            spans[k] = s
            lastEnd = s.1
        }
        // 没对上的行：夹在前后两行中间
        for k in spans.indices where spans[k] == nil {
            let prevEnd = spans[..<k].reversed().compactMap { $0 }.first?.1 ?? -1
            let nextStart = spans[(k + 1)...].compactMap { $0 }.first?.0 ?? sChars.count
            let a = min(sChars.count - 1, prevEnd + 1)
            let b = max(a, min(sChars.count - 1, nextStart - 1))
            spans[k] = (a, b)
        }
        return spans.map { sp in
            guard let sp else { return nil }
            return (max(0, sStart[sp.0] - 0.2), sEnd[sp.1] + 0.25)
        }
    }

    private static func longestChain(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        var tails: [Int] = []
        var prev = [Int](repeating: -1, count: pairs.count)
        for (k, pr) in pairs.enumerated() {
            var lo = 0
            var hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pairs[tails[mid]].1 < pr.1 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[k] = tails[lo - 1] }
            if lo == tails.count { tails.append(k) } else { tails[lo] = k }
        }
        var out: [(Int, Int)] = []
        var k = tails.last ?? -1
        while k >= 0 {
            out.append(pairs[k])
            k = prev[k]
        }
        return out.reversed()
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
