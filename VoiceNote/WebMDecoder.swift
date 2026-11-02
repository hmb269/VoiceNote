import AVFoundation
import Copus

/// 解 WebM / MKA（网页录音、网页版会议常见）：自己拆 Matroska 容器，Opus 交给系统解码
enum WebMDecoder {
    struct Track {
        var number = 0
        var codec = ""
        var channels = 1
        var rate = 48000.0
        var privateData = Data()
    }

    /// 流式拆包：一个一个吐出音轨的数据包
    struct Demuxer {
        let data: Data
        var pos = 0
        var tracks: [Track] = []
        var current: Track?
        var audio: Track?

        init(data: Data) { self.data = data }

        private func byte(_ i: Int) -> UInt8 { data[data.startIndex + i] }

        /// 读 EBML 变长整数。keepMarker=true 用于元素 ID
        private mutating func vint(keepMarker: Bool) -> (value: UInt64, unknown: Bool)? {
            guard pos < data.count else { return nil }
            let first = byte(pos)
            var len = 1
            var mask: UInt8 = 0x80
            while len <= 8 && first & mask == 0 { mask >>= 1; len += 1 }
            guard len <= 8, pos + len <= data.count else { return nil }
            var v = UInt64(keepMarker ? first : first & (mask &- 1))
            var allOnes = (first & (mask &- 1)) == (mask &- 1)
            for k in 1..<len {
                let b = byte(pos + k)
                v = (v << 8) | UInt64(b)
                if b != 0xFF { allOnes = false }
            }
            pos += len
            return (v, !keepMarker && allOnes)
        }

        private func uint(_ start: Int, _ size: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<min(size, 8) { v = (v << 8) | UInt64(byte(start + k)) }
            return v
        }

        private func float(_ start: Int, _ size: Int) -> Double {
            let bits = uint(start, size)
            if size == 4 { return Double(Float(bitPattern: UInt32(bits))) }
            if size == 8 { return Double(bitPattern: bits) }
            return 0
        }

        private mutating func finishTrack() {
            if let t = current { tracks.append(t) }
            current = nil
        }

        mutating func pickAudio() -> Track? {
            if audio == nil {
                finishTrack()
                audio = tracks.first { $0.codec.hasPrefix("A_") }
            }
            return audio
        }

        /// 下一个音频包，读完返回 nil
        mutating func next() -> Data? {
            let masters: Set<UInt64> = [0x18538067, 0x1654AE6B, 0x1F43B675, 0xA0, 0xE1]
            while pos < data.count {
                guard let id = vint(keepMarker: true)?.value,
                      let sz = vint(keepMarker: false) else { return nil }
                let start = pos
                if masters.contains(id) { continue }          // 容器：直接往里走
                if id == 0xAE { finishTrack(); current = Track(); continue }   // TrackEntry
                if sz.unknown { return nil }
                let size = Int(min(sz.value, UInt64(data.count - start)))
                pos = start + size
                switch id {
                case 0xD7: let v = Int(uint(start, size)); current?.number = v
                case 0x86:
                    let v = String(decoding: data[(data.startIndex + start)..<(data.startIndex + start + size)], as: UTF8.self)
                        .trimmingCharacters(in: .controlCharacters)
                    current?.codec = v
                case 0x9F: let v = max(1, Int(uint(start, size))); current?.channels = v
                case 0xB5: let v = float(start, size); current?.rate = v
                case 0x63A2: let v = data[(data.startIndex + start)..<(data.startIndex + start + size)]; current?.privateData = v
                case 0xA3, 0xA1:                              // SimpleBlock / Block
                    guard let a = pickAudio() else { continue }
                    var p = start
                    // 轨道号
                    let save = pos
                    pos = p
                    guard let tn = vint(keepMarker: false) else { pos = save; continue }
                    p = pos
                    pos = save
                    guard Int(tn.value) == a.number, p + 3 <= start + size else { continue }
                    let flags = byte(p + 2)
                    guard flags & 0x06 == 0 else { continue }  // 带 lacing 的少见，跳过
                    let payloadStart = p + 3
                    guard payloadStart < start + size else { continue }
                    return Data(data[(data.startIndex + payloadStart)..<(data.startIndex + start + size)])
                default: break
                }
            }
            return nil
        }
    }

    static func decodeToM4A(_ src: URL, dest: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: src, options: .alwaysMapped)
            var demux = Demuxer(data: data)
            guard let first = demux.next(), let track = demux.audio else {
                throw VNError("WebM 文件里没找到音轨")
            }
            guard track.codec == "A_OPUS" else {
                throw VNError("这个 WebM 里的声音是 \(track.codec) 编码，暂时解不了，请先转成 mp3/m4a 再导入")
            }
            _ = track
            // 用内置 libopus 解码，直接解成单声道 48kHz（立体声会自动混成单声道）
            var err: Int32 = 0
            guard let dec = opus_decoder_create(48000, 1, &err), err == 0 else {
                throw VNError("Opus 解码器初始化失败（\(err)）")
            }
            defer { opus_decoder_destroy(dec) }
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                          channels: 1, interleaved: false) else { throw VNError("内存不足") }
            let file = try AVAudioFile(forWriting: dest, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)

            var pcm = [Float](repeating: 0, count: 5760)
            var batch: [Float] = []
            batch.reserveCapacity(200_000)
            var wrote = 0
            var bad = 0
            func flush() throws {
                guard !batch.isEmpty,
                      let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(batch.count)) else { return }
                b.frameLength = AVAudioFrameCount(batch.count)
                batch.withUnsafeBufferPointer { p in
                    b.floatChannelData![0].update(from: p.baseAddress!, count: batch.count)
                }
                try file.write(from: b)
                wrote += batch.count
                batch.removeAll(keepingCapacity: true)
            }
            var pkt: Data? = first
            while let p = pkt {
                let n = p.withUnsafeBytes { raw in
                    pcm.withUnsafeMutableBufferPointer { out in
                        opus_decode_float(dec, raw.bindMemory(to: UInt8.self).baseAddress, Int32(p.count),
                                          out.baseAddress!, 5760, 0)
                    }
                }
                if n > 0 {
                    batch.append(contentsOf: pcm[0..<Int(n)])
                    if batch.count >= 192_000 { try flush() }
                } else {
                    bad += 1
                }
                pkt = demux.next()
            }
            try flush()
            if wrote == 0 { throw VNError("WebM 解码后没有声音（坏包 \(bad) 个）") }
        }.value
    }
}
