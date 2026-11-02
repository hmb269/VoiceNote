import Foundation

/// 流式解压 .tar.bz2：边解压边写文件，不会把整个包读进内存
enum TarBz2 {
    /// - stripPrefix: 包里的顶层目录名，去掉后写到 destDir
    /// - keep: 返回 false 的文件跳过（比如测试音频）
    static func extract(_ archive: URL, to destDir: URL, stripPrefix: String,
                        keep: @escaping (String) -> Bool,
                        progress: (Double) -> Void) throws {
        let totalIn = ((try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? NSNumber)?.doubleValue ?? 1
        guard let fh = FileHandle(forReadingAtPath: archive.path) else { throw VNError("打不开下载的压缩包") }
        defer { try? fh.close() }

        var parser = TarParser(destDir: destDir, stripPrefix: stripPrefix, keep: keep)
        var strm = bz_stream()
        guard BZ2_bzDecompressInit(&strm, 0, 0) == BZ_OK else { throw VNError("解压初始化失败") }
        defer { BZ2_bzDecompressEnd(&strm) }

        let outSize = 1 << 20
        let outBuf = UnsafeMutablePointer<CChar>.allocate(capacity: outSize)
        defer { outBuf.deallocate() }
        var readIn = 0.0

        while true {
            let chunk = fh.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            readIn += Double(chunk.count)
            var input = chunk
            try input.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                strm.next_in = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                strm.avail_in = UInt32(raw.count)
                while strm.avail_in > 0 {
                    strm.next_out = outBuf
                    strm.avail_out = UInt32(outSize)
                    let rc = BZ2_bzDecompress(&strm)
                    let produced = outSize - Int(strm.avail_out)
                    if produced > 0 {
                        try parser.feed(UnsafeRawBufferPointer(start: outBuf, count: produced))
                    }
                    if rc == BZ_STREAM_END {
                        // 可能是多段拼接的 bz2，重新开始下一段
                        let leftPtr = strm.next_in
                        let leftCount = strm.avail_in
                        BZ2_bzDecompressEnd(&strm)
                        strm = bz_stream()
                        guard BZ2_bzDecompressInit(&strm, 0, 0) == BZ_OK else { throw VNError("解压失败") }
                        strm.next_in = leftPtr
                        strm.avail_in = leftCount
                        if leftCount == 0 { break }
                    } else if rc != BZ_OK {
                        throw VNError("压缩包损坏（\(rc)），删除后重新下载")
                    }
                }
            }
            progress(min(1, readIn / totalIn))
        }
        try parser.finish()
    }
}

private struct TarParser {
    let destDir: URL
    let stripPrefix: String
    let keep: (String) -> Bool

    private var header = Data()
    private var remaining: Int = 0      // 当前文件还剩多少字节
    private var padding: Int = 0        // 文件数据后的补齐
    private var out: FileHandle?
    private var longName: String?
    private var paxPath: String?
    private var collecting: Data?       // 收集 GNU 长文件名 / pax 头
    private var collectKind: Character = " "

    init(destDir: URL, stripPrefix: String, keep: @escaping (String) -> Bool) {
        self.destDir = destDir
        self.stripPrefix = stripPrefix
        self.keep = keep
    }

    mutating func feed(_ buf: UnsafeRawBufferPointer) throws {
        var i = 0
        let n = buf.count
        while i < n {
            if remaining > 0 {
                let take = min(remaining, n - i)
                let slice = Data(bytes: buf.baseAddress! + i, count: take)
                if collecting != nil {
                    collecting!.append(slice)
                } else {
                    out?.write(slice)
                }
                remaining -= take
                i += take
                if remaining == 0 { try endEntry() }
                continue
            }
            if padding > 0 {
                let take = min(padding, n - i)
                padding -= take
                i += take
                continue
            }
            let take = min(512 - header.count, n - i)
            header.append(Data(bytes: buf.baseAddress! + i, count: take))
            i += take
            if header.count == 512 {
                try startEntry(header)
                header.removeAll(keepingCapacity: true)
            }
        }
    }

    mutating func finish() throws {
        try? out?.close()
        out = nil
    }

    private mutating func startEntry(_ h: Data) throws {
        if h.allSatisfy({ $0 == 0 }) { return }   // 结尾的空块
        func str(_ r: Range<Int>) -> String {
            let bytes = h[r].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let sizeStr = str(124..<136).trimmingCharacters(in: .whitespaces)
        let size = Int(sizeStr, radix: 8) ?? 0
        let type = Character(UnicodeScalar(h[156]))
        var name = str(0..<100)
        let prefix = str(345..<500)
        if str(257..<262) == "ustar", !prefix.isEmpty { name = prefix + "/" + name }
        if let ln = longName { name = ln; longName = nil }
        if let pp = paxPath { name = pp; paxPath = nil }

        remaining = size
        padding = (512 - size % 512) % 512

        switch type {
        case "L", "x", "g":
            collecting = Data()
            collectKind = type
        case "5":
            if let path = target(name) {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            }
        case "0", "\0", "7":
            if let path = target(name), keep(relative(name)) {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path.path, contents: nil)
                out = try FileHandle(forWritingTo: path)
            } else {
                out = nil
            }
        default:
            out = nil
        }
        if remaining == 0 { try endEntry() }
    }

    private mutating func endEntry() throws {
        if let c = collecting {
            if collectKind == "L" {
                longName = String(decoding: c.prefix { $0 != 0 }, as: UTF8.self)
            } else if collectKind == "x" {
                // pax 格式：「长度 key=value\n」
                for line in String(decoding: c, as: UTF8.self).split(separator: "\n") {
                    if let r = line.range(of: " path=") {
                        paxPath = String(line[r.upperBound...])
                    }
                }
            }
            collecting = nil
        }
        try? out?.close()
        out = nil
    }

    private func relative(_ name: String) -> String {
        var n = name
        if n.hasPrefix("./") { n.removeFirst(2) }
        if n.hasPrefix(stripPrefix) { n.removeFirst(stripPrefix.count) }
        return n
    }

    private func target(_ name: String) -> URL? {
        let rel = relative(name)
        guard !rel.isEmpty, !rel.contains("..") else { return nil }
        return destDir.appendingPathComponent(rel)
    }
}
