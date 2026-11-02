import AVFoundation

/// 转写 / 整理进行中时循环播放一段静音，让 App 切到后台后继续跑，不被系统挂起
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    private var player: AVAudioPlayer?
    private var active = false

    func update(active: Bool) {
        guard active != self.active else { return }
        self.active = active
        active ? start() : stop()
    }

    /// 录音结束会关掉音频会话，任务还在跑的话重新拉起来
    func kick() {
        guard active else { return }
        player?.stop()
        player = nil
        start()
    }

    private func start() {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord {
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? s.setActive(true)
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silentWav())
            player?.numberOfLoops = -1
            player?.volume = 0
        }
        player?.play()
    }

    private func stop() {
        player?.stop()
        player = nil
        if !PhoneRecorder.shared.isRecording {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// 1 秒 8kHz 单声道静音 WAV
    private static func silentWav() -> Data {
        let rate: UInt32 = 8000, samples = 8000
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
        d.append(Data(count: samples * 2))
        return d
    }
}
