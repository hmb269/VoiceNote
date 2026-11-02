import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 每条录音的「封面」：按 id 生成固定的渐变配色和声波图案
struct CoverArt: View {
    let seed: UUID
    var cornerRadius: CGFloat = 18
    var barCount = 28
    var showBars = true

    private static let palettes: [(Color, Color, Color)] = [
        (Color(red: 0.16, green: 0.13, blue: 0.42), Color(red: 0.52, green: 0.22, blue: 0.72), Color(red: 0.98, green: 0.45, blue: 0.62)),
        (Color(red: 0.45, green: 0.07, blue: 0.16), Color(red: 0.89, green: 0.29, blue: 0.33), Color(red: 1.00, green: 0.70, blue: 0.45)),
        (Color(red: 0.03, green: 0.20, blue: 0.30), Color(red: 0.07, green: 0.48, blue: 0.55), Color(red: 0.55, green: 0.92, blue: 0.80)),
        (Color(red: 0.30, green: 0.12, blue: 0.05), Color(red: 0.80, green: 0.42, blue: 0.12), Color(red: 1.00, green: 0.82, blue: 0.45)),
        (Color(red: 0.06, green: 0.12, blue: 0.24), Color(red: 0.18, green: 0.32, blue: 0.70), Color(red: 0.50, green: 0.75, blue: 1.00)),
        (Color(red: 0.12, green: 0.18, blue: 0.14), Color(red: 0.20, green: 0.48, blue: 0.36), Color(red: 0.80, green: 0.90, blue: 0.55)),
        (Color(red: 0.25, green: 0.06, blue: 0.28), Color(red: 0.66, green: 0.20, blue: 0.48), Color(red: 1.00, green: 0.60, blue: 0.38)),
    ]

    private var bytes: [UInt8] {
        let u = seed.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    var body: some View {
        let b = bytes
        let pal = Self.palettes[Int(b[0]) % Self.palettes.count]
        ZStack {
            LinearGradient(colors: [pal.0, pal.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [pal.2.opacity(0.75), .clear],
                           center: UnitPoint(x: 0.2 + Double(b[1] % 60) / 100, y: 0.1),
                           startRadius: 0, endRadius: 220)
            RadialGradient(colors: [pal.1.opacity(0.6), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 180)
            if showBars {
                Canvas { ctx, size in
                    let n = barCount
                    let gap = size.width * 0.012
                    let w = (size.width * 0.78 - gap * CGFloat(n - 1)) / CGFloat(n)
                    let x0 = size.width * 0.11
                    let mid = size.height * 0.56
                    for i in 0..<n {
                        let v = Double(b[(i * 7 + 3) % 16] ^ UInt8(truncatingIfNeeded: i * 37)) / 255
                        let env = sin(Double(i + 1) / Double(n + 1) * .pi)
                        let h = CGFloat(0.12 + 0.88 * v * env) * size.height * 0.42
                        let r = CGRect(x: x0 + CGFloat(i) * (w + gap), y: mid - h / 2, width: w, height: h)
                        ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(.white.opacity(0.5)))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 系统文件选择器，选中后由系统先拷贝一份给 App，不受权限限制
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie]
        + ["webm", "mka", "opus", "ogg"].compactMap { UTType(filenameExtension: $0) }
    var multiple = true
    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.allowsMultipleSelection = multiple
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
