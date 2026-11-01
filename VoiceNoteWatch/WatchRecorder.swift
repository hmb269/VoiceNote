import AVFoundation
import Foundation
import WatchConnectivity

extension Notification.Name {
    static let vnTransferChanged = Notification.Name("vnTransferChanged")
}

enum WatchStorage {
    static var dir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Outbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    /// 正在录的文件名，补发时跳过它
    static var activeFileName: String?
}

@MainActor
final class WatchRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var pending = 0
    @Published var message = ""

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt = Date()

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                if granted {
                    self.beginRecording()
                } else {
                    self.message = "没有麦克风权限，到手表 设置 → 隐私 里打开"
                }
            }
        }
    }

    private func beginRecording() {
        guard !isRecording else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let name = "\(UUID().uuidString).m4a"
            let url = WatchStorage.dir.appendingPathComponent(name)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 22050,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else {
                message = "录音启动失败"
                return
            }
            WatchStorage.activeFileName = name
            recorder = r
            startedAt = Date()
            elapsed = 0
            isRecording = true
            message = ""
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let r = self.recorder else { return }
                    self.elapsed = r.currentTime
                }
            }
        } catch {
            message = "录音失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        guard let r = recorder else { return }
        r.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        WatchStorage.activeFileName = nil
        try? AVAudioSession.sharedInstance().setActive(false)

        WatchSession.shared.send(url: r.url, createdAt: startedAt)
        message = "已保存，会自动传到 iPhone"
        refreshPending()
    }

    func refreshPending() {
        let files = (try? FileManager.default.contentsOfDirectory(at: WatchStorage.dir,
                                                                    includingPropertiesForKeys: nil)) ?? []
        pending = files.filter { $0.pathExtension == "m4a" && $0.lastPathComponent != WatchStorage.activeFileName }.count
        if pending == 0 && message.hasPrefix("已保存") {
            message = "已传到 iPhone ✓"
        }
    }
}

final class WatchSession: NSObject, WCSessionDelegate {
    static let shared = WatchSession()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(url: URL, createdAt: Date) {
        let s = WCSession.default
        guard s.activationState == .activated else { return } // 激活后会自动补发
        s.transferFile(url, metadata: ["createdAt": createdAt.timeIntervalSince1970])
    }

    /// 把 Outbox 里还没在传的文件重新发一遍（比如上次传到一半 App 被关了）
    func resendLeftovers() {
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        let outstanding = Set(s.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: WatchStorage.dir,
                                                                    includingPropertiesForKeys: [.creationDateKey])) ?? []
        for f in files where f.pathExtension == "m4a" {
            let name = f.lastPathComponent
            if outstanding.contains(name) || name == WatchStorage.activeFileName { continue }
            let created = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            s.transferFile(f, metadata: ["createdAt": created.timeIntervalSince1970])
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            resendLeftovers()
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error == nil {
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .vnTransferChanged, object: nil)
        }
    }
}
