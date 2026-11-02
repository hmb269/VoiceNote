import AVFoundation
import UIKit

@MainActor
final class PhoneRecorder: ObservableObject {
    static let shared = PhoneRecorder()

    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 36)

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt = Date()
    private var fileName = ""

    func start() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            throw VNError("没有麦克风权限，请到 设置 → 隐私与安全性 → 麦克风 里打开")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        fileName = "\(UUID().uuidString).m4a"
        let url = Storage.recordingsDir.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw VNError("录音启动失败") }

        recorder = r
        startedAt = Date()
        elapsed = 0
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let r = recorder else { return }
        elapsed = r.currentTime
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        level = max(0, min(1, (db + 50) / 50))
        levels.removeFirst()
        levels.append(level)
    }

    func stop() -> (fileName: String, startedAt: Date)? {
        guard let r = recorder else { return nil }
        r.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        level = 0
        levels = Array(repeating: 0, count: 36)
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (fileName, startedAt)
    }
}

@MainActor
final class AudioPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.enableRate = true
        player?.rate = rate
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        current = 0
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying {
            stopAt = nil
            p.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            let s = AVAudioSession.sharedInstance()
            // 用 playAndRecord + 扬声器，播放时不会打断正在进行的录音
            try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try? s.setActive(true)
            p.play()
            isPlaying = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
        }
    }

    /// 校对用：stopAt 不为空时播到这个时间就停
    private var stopAt: Double?

    func play(from start: Double, until end: Double?) {
        guard let p = player else { return }
        stopAt = end
        // 往前留一点，避免句首被吃掉
        seek(max(0, start - 0.15))
        if !p.isPlaying { toggle() }
    }

    private func update() {
        guard let p = player else { return }
        current = p.currentTime
        if let s = stopAt, current >= s {
            stopAt = nil
            p.pause()
        }
        if !p.isPlaying {
            isPlaying = false
            timer?.invalidate()
        }
    }

    func setRate(_ r: Float) {
        rate = r
        player?.rate = r
    }

    func cycleRate() {
        let i = Self.rates.firstIndex(of: rate) ?? 1
        rate = Self.rates[(i + 1) % Self.rates.count]
        player?.rate = rate
    }

    func seek(_ t: Double) {
        player?.currentTime = t
        current = t
    }

    func skip(_ delta: Double) {
        seek(max(0, min(duration, current + delta)))
    }

    func stop() {
        player?.stop()
        isPlaying = false
        timer?.invalidate()
    }
}
