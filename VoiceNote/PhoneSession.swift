import Foundation
import WatchConnectivity

/// 接收手表传过来的录音文件
final class PhoneSession: NSObject, WCSessionDelegate {
    static let shared = PhoneSession()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // 必须在这个方法返回前把文件移走，否则系统会删掉
        let ext = file.fileURL.pathExtension.isEmpty ? "m4a" : file.fileURL.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        let dest = Storage.recordingsDir.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: dest)
        } catch {
            do { try FileManager.default.copyItem(at: file.fileURL, to: dest) } catch { return }
        }
        let meta = file.metadata ?? [:]
        let ts = meta["createdAt"] as? Double
        let created = ts.map { Date(timeIntervalSince1970: $0) } ?? Date()
        Task { @MainActor in
            Processor.shared.ingest(fileName: name, source: .watch, createdAt: created)
        }
    }
}
