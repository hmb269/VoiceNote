import AVFoundation
import CoreMedia

struct AudioChunk {
    let url: URL
    let start: Double
    let duration: Double
}

private final class EndFlag {
    var value = false
}

enum AudioTools {
    /// 看文件开头的字节判断真实格式（很多文件后缀是 mp3，里面其实是 aac/m4a/amr）
    static func sniffExtension(_ url: URL) -> String? {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? fh.close() }
        var head = [UInt8](fh.readData(ofLength: 4096))
        guard head.count >= 12 else { return nil }
        func ascii(_ r: Range<Int>) -> String { String(bytes: head[r], encoding: .ascii) ?? "" }
        if ascii(4..<8) == "ftyp" { return "m4a" }
        if ascii(0..<4) == "RIFF" { return "wav" }
        if ascii(0..<4) == "OggS" { return "ogg" }
        if ascii(0..<4) == "fLaC" { return "flac" }
        if head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3 { return "webm" }
        if ascii(0..<4) == "caff" { return "caf" }
        if ascii(0..<4) == "FORM" { return "aiff" }
        if ascii(0..<5) == "#!AMR" { return ascii(0..<8) == "#!AMR-WB" ? "awb" : "amr" }
        if ascii(0..<9).contains("SILK") || ascii(1..<10).contains("SILK") { return "silk" }
        // 跳过 ID3 标签再看帧头
        var i = 0
        if ascii(0..<3) == "ID3", head.count >= 10 {
            let size = (Int(head[6]) << 21) | (Int(head[7]) << 14) | (Int(head[8]) << 7) | Int(head[9])
            let skip = 10 + size
            if skip + 4 > head.count {
                try? fh.seek(toOffset: UInt64(skip))
                head = [UInt8](fh.readData(ofLength: 4096))
                i = 0
            } else {
                i = skip
            }
        }
        while i + 1 < head.count {
            if head[i] == 0xFF && (head[i + 1] & 0xE0) == 0xE0 {
                // 0xFFF1 / 0xFFF9 是 AAC ADTS，其余是 MP3
                return (head[i + 1] & 0xF6) == 0xF0 ? "aac" : "mp3"
            }
            if i + 8 < head.count, String(bytes: head[(i + 4)..<(i + 8)], encoding: .ascii) == "ftyp" { return "m4a" }
            i += 1
            if i > 2048 { break }
        }
        return nil
    }

    /// 能读但时长明显不对：比如 55MB 的 mp3 只读出 0 秒（文件头里写的长度是错的）
    static func looksTruncated(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !["wav", "aif", "aiff", "caf", "flac"].contains(ext) else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 200_000 else { return false }
        let d = duration(of: url)
        // 压缩音频最高 320kbps ≈ 40KB/秒，超过 60KB/秒说明只读到了一小段
        return d < 1 || Double(size) / d > 60_000
    }

    /// 前几个字节的十六进制，报错时用来判断是什么文件
    static func headHex(_ url: URL) -> String {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return "" }
        defer { try? fh.close() }
        return fh.readData(ofLength: 12).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// 用内置的 minimp3 逐帧解码 mp3，不依赖文件头里的长度信息，坏头、拼接过的 mp3 也能读
    static func decodeMP3ToM4A(_ src: URL, dest: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let fh = FileHandle(forReadingAtPath: src.path) else { throw VNError("打不开文件") }
            defer { try? fh.close() }
            var dec = mp3dec_t()
            mp3dec_init(&dec)
            var info = mp3dec_frame_info_t()
            var pcm = [Int16](repeating: 0, count: 2304)
            var buf: [UInt8] = []
            var pos = 0
            var eof = false
            var out: AVAudioFile?
            var fmt: AVAudioFormat?
            var rate: Int32 = 0
            var mono: [Int16] = []
            mono.reserveCapacity(70_000)

            func flush() throws {
                guard let out, let fmt, !mono.isEmpty,
                      let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(mono.count)) else { return }
                b.frameLength = AVAudioFrameCount(mono.count)
                mono.withUnsafeBufferPointer { p in
                    b.int16ChannelData![0].update(from: p.baseAddress!, count: mono.count)
                }
                try out.write(from: b)
                mono.removeAll(keepingCapacity: true)
            }
            func readMore() {
                if pos > 0 { buf.removeFirst(pos); pos = 0 }
                let d = fh.readData(ofLength: 1 << 20)
                if d.isEmpty { eof = true } else { buf.append(contentsOf: d) }
            }

            while true {
                if !eof && buf.count - pos < 16_384 { readMore() }
                let remain = buf.count - pos
                if remain <= 0 { break }
                let samples = buf.withUnsafeBufferPointer { b in
                    pcm.withUnsafeMutableBufferPointer { p in
                        mp3dec_decode_frame(&dec, b.baseAddress! + pos, Int32(remain), p.baseAddress!, &info)
                    }
                }
                if info.frame_bytes == 0 {
                    if eof { break }
                    readMore()
                    continue
                }
                pos += Int(info.frame_bytes)
                guard samples > 0 else { continue }
                if rate == 0 {
                    rate = info.hz
                    fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: true)
                    out = try AVAudioFile(forWriting: dest, settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: Double(rate),
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 64000,
                    ], commonFormat: .pcmFormatInt16, interleaved: true)
                }
                guard info.hz == rate else { continue }
                let n = Int(samples)
                if info.channels == 2 {
                    for i in 0..<n { mono.append(Int16((Int32(pcm[2 * i]) + Int32(pcm[2 * i + 1])) / 2)) }
                } else {
                    mono.append(contentsOf: pcm[0..<n])
                }
                if mono.count >= 65_536 { try flush() }
            }
            try flush()
            if out == nil { throw VNError("文件里找不到 mp3 音频数据") }
        }.value
        guard isReadable(dest) else { throw VNError("mp3 解码后还是读不了") }
    }

    /// 系统能不能直接读这个音频
    static func isReadable(_ url: URL) -> Bool {
        guard let f = try? AVAudioFile(forReading: url) else { return false }
        return f.length > 0
    }

    /// 读不了的格式（微信 silk 除外）转成 m4a：先用系统导出，不行再逐帧解码重编码
    static func convertToM4A(_ src: URL, dest: URL) async throws {
        try? FileManager.default.removeItem(at: dest)
        var src = src
        if let real = sniffExtension(src), real != src.pathExtension.lowercased() {
            let fixed = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(real)")
            try? FileManager.default.copyItem(at: src, to: fixed)
            src = fixed
        }
        if ["webm", "mka", "mkv"].contains(src.pathExtension.lowercased()) {
            try await WebMDecoder.decodeToM4A(src, dest: dest)
            guard isReadable(dest) else { throw VNError("WebM 转换后还是读不了") }
            return
        }
        if src.pathExtension.lowercased() == "mp3" {
            // mp3 先用内置解码器，最稳；不行再交给系统
            do {
                try await decodeMP3ToM4A(src, dest: dest)
                if !looksTruncated(dest) && duration(of: dest) >= 1 { return }
            } catch {}
            try? FileManager.default.removeItem(at: dest)
        }
        if src.pathExtension == "silk" {
            throw VNError("这是微信语音（silk 格式），iOS 不能直接解码。请在微信里转发到电脑，用工具转成 mp3 再导入")
        }
        let asset = AVURLAsset(url: src)
        if let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            s.outputURL = dest
            s.outputFileType = .m4a
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                s.exportAsynchronously { c.resume() }
            }
            if s.status == .completed, isReadable(dest) { return }
            try? FileManager.default.removeItem(at: dest)
        }
        // 第二种办法：AVAssetReader 解码成 PCM，再写成 AAC
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw VNError("系统不认识这个音频格式。微信语音（silk/amr）、opus、wma 这类格式请先用其他 App 转成 m4a 或 mp3 再导入")
        }
        // 记下编码格式，失败时告诉用户
        var codec = src.pathExtension.lowercased()
        if let desc = try? await track.load(.formatDescriptions).first {
            let sub = CMFormatDescriptionGetMediaSubType(desc)
            let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((sub >> $0) & 0xFF))) }
            codec += " / " + String(chars).trimmingCharacters(in: .whitespaces)
        }
        let codecInfo = codec
        try await Task.detached(priority: .userInitiated) {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
            ])
            reader.add(out)
            guard reader.startReading() else {
                throw VNError("iOS 解不开这个音频（格式：\(codecInfo)）。请先用其他 App 转成 m4a/mp3 再导入，或把文件发给开发者看看")
            }
            let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
            let file = try AVAudioFile(forWriting: dest, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48000,
            ], commonFormat: .pcmFormatInt16, interleaved: true)
            while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
                let len = CMBlockBufferGetDataLength(block)
                let frames = AVAudioFrameCount(len / 2)
                guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { continue }
                buf.frameLength = frames
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len,
                                               destination: buf.int16ChannelData![0])
                try file.write(from: buf)
            }
            if reader.status == .failed {
                throw VNError("iOS 解不开这个音频（格式：\(codecInfo)）。请先用其他 App 转成 m4a/mp3 再导入，或把文件发给开发者看看")
            }
        }.value
        guard isReadable(dest) else { throw VNError("转换后的音频还是读不了") }
    }

    static func duration(of url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = f.processingFormat.sampleRate
        return rate > 0 ? Double(f.length) / rate : 0
    }

    /// 把任意音频转成 16kHz 单声道 16bit WAV，并按 chunkSeconds 切成多段。
    /// 返回的文件都在一个临时目录里，用完调用 cleanup 删除。
    static func splitToWav(url: URL, chunkSeconds: Double) throws -> [AudioChunk] {
        let input = try AVAudioFile(forReading: url)
        let inFormat = input.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16000,
                                            channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw VNError("无法读取这个音频格式")
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let framesPerChunk = AVAudioFrameCount(max(5, chunkSeconds) * 16000)
        let readSize: AVAudioFrameCount = 8192
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: readSize) else {
            throw VNError("内存不足")
        }

        var urls: [URL] = []
        var chunkFrames: [AVAudioFrameCount] = []
        var current: AVAudioFile?
        var framesInCurrent: AVAudioFrameCount = 0
        let flag = EndFlag()

        func openNewChunk() throws {
            current = nil
            let u = tmpDir.appendingPathComponent(String(format: "chunk-%04d.wav", urls.count))
            current = try AVAudioFile(forWriting: u,
                                      settings: wavSettings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
            urls.append(u)
            chunkFrames.append(0)
            framesInCurrent = 0
        }

        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096) else { break }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if flag.value {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inBuf, frameCount: readSize)
                } catch {
                    flag.value = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    flag.value = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let convError { throw convError }

            if outBuf.frameLength > 0 {
                if current == nil || framesInCurrent >= framesPerChunk {
                    try openNewChunk()
                }
                try current?.write(from: outBuf)
                framesInCurrent += outBuf.frameLength
                chunkFrames[chunkFrames.count - 1] += outBuf.frameLength
            }

            if status == .endOfStream || status == .error { break }
            if status == .inputRanDry && flag.value { break }
        }
        current = nil

        if urls.isEmpty { throw VNError("音频是空的") }
        var result: [AudioChunk] = []
        var offset: Double = 0
        for (i, u) in urls.enumerated() {
            let d = Double(chunkFrames[i]) / 16000
            result.append(AudioChunk(url: u, start: offset, duration: d))
            offset += d
        }
        return result
    }

    /// 把音频转成 16kHz 单声道 Float，一块一块交给 handler（不会一次读进内存）
    static func forEach16kMono(url: URL, handler: ([Float]) throws -> Void) throws {
        let input = try AVAudioFile(forReading: url)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: outFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else {
            throw VNError("无法读取这个音频格式")
        }
        let flag = EndFlag()
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16000) else { break }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if flag.value {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inBuf, frameCount: 8192)
                } catch {
                    flag.value = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    flag.value = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let convError { throw convError }
            if outBuf.frameLength > 0, let ch = outBuf.floatChannelData?[0] {
                try handler(Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength))))
            }
            if status == .endOfStream || status == .error { break }
            if status == .inputRanDry && flag.value { break }
        }
    }

    static func cleanup(_ chunks: [AudioChunk]) {
        guard let dir = chunks.first?.url.deletingLastPathComponent() else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
