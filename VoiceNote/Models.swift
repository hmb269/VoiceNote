import Foundation
import SwiftData

enum RecordingStatus: String, Codable {
    case idle, transcribing, organizing, done, failed
}

enum RecordingSource: String, Codable {
    case phone, watch, imported

    var icon: String {
        switch self {
        case .phone: return "iphone"
        case .watch: return "applewatch"
        case .imported: return "square.and.arrow.down"
        }
    }

    var label: String {
        switch self {
        case .phone: return "手机录音"
        case .watch: return "手表录音"
        case .imported: return "导入"
        }
    }
}

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    var fileName: String
    var sourceRaw: String
    var transcript: String
    var summary: String
    var statusRaw: String
    var errorMessage: String
    var engineUsed: String
    var autoPending: Bool
    var segmentsData: Data? = nil
    var isFavorite: Bool = false
    var highlightsData: Data? = nil
    var highlightSummary: String = ""

    var highlights: [Highlight] {
        get {
            guard let highlightsData,
                  let h = try? JSONDecoder().decode([Highlight].self, from: highlightsData) else { return [] }
            return h
        }
        set { highlightsData = try? JSONEncoder().encode(newValue) }
    }

    init(title: String, createdAt: Date, duration: Double, fileName: String, source: RecordingSource) {
        self.id = UUID()
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.fileName = fileName
        self.sourceRaw = source.rawValue
        self.transcript = ""
        self.summary = ""
        self.statusRaw = RecordingStatus.idle.rawValue
        self.errorMessage = ""
        self.engineUsed = ""
        self.autoPending = true
    }

    var status: RecordingStatus {
        get { RecordingStatus(rawValue: statusRaw) ?? .idle }
        set { statusRaw = newValue.rawValue }
    }

    /// 带时间的分句。写入时同时更新 transcript
    var segments: [TranscriptSegment] {
        get {
            guard let segmentsData,
                  let s = try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData) else { return [] }
            return s
        }
        set {
            segmentsData = try? JSONEncoder().encode(newValue)
            let text = newValue.map(\.text).joined(separator: "\n")
            transcript = text.isEmpty ? Recording.noSpeechText : text
        }
    }

    var source: RecordingSource {
        RecordingSource(rawValue: sourceRaw) ?? .phone
    }

    var fileURL: URL {
        Storage.recordingsDir.appendingPathComponent(fileName)
    }

    var hasSpeech: Bool {
        !transcript.isEmpty && transcript != Recording.noSpeechText
    }

    static let noSpeechText = "（没有识别到说话内容）"

    static func defaultTitle(for date: Date, source: RecordingSource) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return "\(source.label) \(f.string(from: date))"
    }
}

/// 用户标记的重点句
struct Highlight: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var start: Double?
    var end: Double?
    var from: String          // 「原文」或「整理」
    var createdAt = Date()
}

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var speaker: Int? = nil

    func contains(_ t: Double) -> Bool { t >= start && t < end }
}

enum DataStore {
    /// App 和快捷指令共用同一个数据库
    static let shared: ModelContainer = {
        do {
            return try ModelContainer(for: Recording.self)
        } catch {
            fatalError("数据库打开失败：\(error)")
        }
    }()
}

enum Storage {
    static var recordingsDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

struct VNError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func formatDuration(_ t: Double) -> String {
    let total = Int(t.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
