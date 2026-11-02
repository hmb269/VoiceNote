import AVFoundation

struct AudioChunk {
    let url: URL
    let start: Double
    let duration: Double
}

private final class EndFlag {
    var value = false
}

enum AudioTools {
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
