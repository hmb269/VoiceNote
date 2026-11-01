import SwiftUI
import AVFoundation

enum Theme {
    /// 主色：珊瑚红（和图标一致）
    static let accent = Color(red: 0.93, green: 0.29, blue: 0.36)
    /// AI 相关：紫色
    static let ai = Color(red: 0.50, green: 0.36, blue: 0.96)
    static let aiGradient = LinearGradient(colors: [Color(red: 0.62, green: 0.38, blue: 0.98),
                                                    Color(red: 0.42, green: 0.36, blue: 0.95)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
    static let recordGradient = LinearGradient(colors: [Color(red: 1.0, green: 0.42, blue: 0.40),
                                                        Color(red: 0.88, green: 0.20, blue: 0.38)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let speakerColors: [Color] = [
        Color(red: 0.20, green: 0.48, blue: 0.95),
        Color(red: 0.93, green: 0.45, blue: 0.20),
        Color(red: 0.18, green: 0.65, blue: 0.48),
        Color(red: 0.75, green: 0.30, blue: 0.70),
    ]

    static func speakerColor(_ name: String) -> Color {
        let key = name.first.map { String($0) } ?? ""
        let order = ["甲", "乙", "丙", "丁", "A", "B", "C", "D"]
        if let i = order.firstIndex(of: key) { return speakerColors[i % speakerColors.count] }
        let h = abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return speakerColors[h % speakerColors.count]
    }
}

extension View {
    /// iOS 26 用液态玻璃，旧系统用毛玻璃
    @ViewBuilder
    func glassBackground(cornerRadius: CGFloat = 24) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        #else
        self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #endif
    }

    func cardBackground(cornerRadius: CGFloat = 20) -> some View {
        self.background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 小胶囊标签
struct Chip: View {
    let icon: String?
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - 波形

enum WaveformLoader {
    private static var cache: [URL: [Float]] = [:]

    @MainActor
    static func cached(_ url: URL) -> [Float]? { cache[url] }

    @MainActor
    static func store(_ url: URL, _ s: [Float]) { cache[url] = s }

    /// 读出整段音频，压缩成 count 个 0~1 的振幅
    static func load(url: URL, count: Int) async -> [Float] {
        await Task.detached(priority: .utility) {
            compute(url: url, count: count)
        }.value
    }

    private static func compute(url: URL, count: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), count > 0 else { return [] }
        let total = file.length
        guard total > 0 else { return [] }
        let format = file.processingFormat
        let perBucket = AVAudioFrameCount(max(1, total / AVAudioFramePosition(count)))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: perBucket) else { return [] }
        var out: [Float] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            do { try file.read(into: buf, frameCount: perBucket) } catch { break }
            let n = Int(buf.frameLength)
            guard n > 0, let ch = buf.floatChannelData?[0] else { break }
            var sum: Float = 0
            var i = 0
            while i < n {
                let v = ch[i]
                sum += v * v
                i += 8
            }
            out.append(sqrt(sum / Float(max(1, n / 8))))
        }
        let peak = out.max() ?? 0
        guard peak > 0 else { return out }
        // 开根号让小声的地方也看得见
        return out.map { min(1, sqrt($0 / peak)) }
    }
}

struct WaveformScrubber: View {
    let samples: [Float]
    let progress: Double
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let n = max(1, samples.count)
                let gap: CGFloat = 2
                let barW = max(1.5, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
                let mid = size.height / 2
                for i in 0..<samples.count {
                    let x = CGFloat(i) * (barW + gap)
                    let h = max(3, CGFloat(samples[i]) * size.height)
                    let rect = CGRect(x: x, y: mid - h / 2, width: barW, height: h)
                    let played = (x + barW / 2) / size.width <= progress
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                             with: .color(played ? Theme.accent : Color.secondary.opacity(0.28)))
                }
                if samples.isEmpty {
                    let r = CGRect(x: 0, y: mid - 2, width: size.width, height: 4)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Color.secondary.opacity(0.25)))
                    let p = CGRect(x: 0, y: mid - 2, width: size.width * progress, height: 4)
                    ctx.fill(Path(roundedRect: p, cornerRadius: 2), with: .color(Theme.accent))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        onSeek(min(1, max(0, v.location.x / geo.size.width)))
                    }
            )
        }
    }
}

/// 录音时的实时声浪
struct LiveLevels: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 3, height: max(4, CGFloat(l) * 34))
            }
        }
        .frame(height: 36)
        .animation(.linear(duration: 0.1), value: levels)
    }
}
