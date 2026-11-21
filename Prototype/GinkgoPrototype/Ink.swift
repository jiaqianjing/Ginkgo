import CoreText
import PDFKit
import PencilKit
import SwiftUI
import Vision

/// A PencilKit canvas over the margin column. A pause after writing turns the ink into a question anchored to
/// the text line beside it; Vision reads the handwriting so A and B can show it as text.
struct InkMarginCanvas: UIViewRepresentable {
    let model: ReaderModel
    let layout: ReaderLayout

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = UIColor(Palette.graphite).withAlphaComponent(0.04)
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput  // finger / mouse in the simulator; Pencil on a device
        canvas.tool = PKInkingTool(.pen, color: UIColor(Palette.graphite), width: 2.4)
        canvas.isScrollEnabled = false
        canvas.delegate = context.coordinator
        context.coordinator.canvas = canvas
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.drawDemo),
                                               name: .demoInk, object: nil)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.model = model
        context.coordinator.pageWidth = layout.pageWidth
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var model: ReaderModel?
        var pageWidth: CGFloat = 0
        weak var canvas: PKCanvasView?
        private var commit: DispatchWorkItem?

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            commit?.cancel()
            guard !canvasView.drawing.strokes.isEmpty else { return }
            let work = DispatchWorkItem { [weak self] in self?.finish() }
            commit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
        }

        /// Writes a short scribbled question mark beside the third paragraph, as a finger would.
        @objc func drawDemo() {
            guard let canvas else { return }
            let y: CGFloat = canvas.bounds.height * 0.42
            let pts: [CGPoint] = (0...40).map { i in
                let t = CGFloat(i) / 40
                if t < 0.75 {
                    let a = -CGFloat.pi * 0.9 + t / 0.75 * CGFloat.pi * 1.4
                    return CGPoint(x: 60 + cos(a) * 16, y: y + sin(a) * 16)
                }
                return CGPoint(x: 60 + 4, y: y + 16 + (t - 0.75) * 60)
            }
            let ink = PKInk(.pen, color: UIColor(Palette.graphite))
            let path = PKStrokePath(controlPoints: pts.enumerated().map {
                PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) * 0.01, size: CGSize(width: 3, height: 3),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: Date())
            let dot = PKStrokePath(controlPoints: [0, 1].map {
                PKStrokePoint(location: CGPoint(x: 64 + CGFloat($0), y: y + 38), timeOffset: 0, size: CGSize(width: 4, height: 4),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: Date())
            canvas.drawing = PKDrawing(strokes: [PKStroke(ink: ink, path: path), PKStroke(ink: ink, path: dot)])
        }

        private func finish() {
            guard let canvas, let model, let pdfView = model.pdfView else { return }
            let drawing = canvas.drawing
            let bounds = drawing.bounds
            guard !bounds.isEmpty, let line = textLine(near: bounds.minY + min(bounds.height, 30) / 2, in: pdfView) else { return }
            let local = drawing.transformed(using: CGAffineTransform(translationX: -bounds.minX + 2, y: -bounds.minY + 2))
            canvas.drawing = PKDrawing()
            let image = drawing.image(from: bounds.insetBy(dx: -6, dy: -6), scale: 2)
            Task { @MainActor in
                let text = await Self.recognize(image)
                withAnimation(.smooth) { model.createInk(local, recognized: text, at: line) }
            }
        }

        /// The text line on the page at the given height of the reader, searching a little up and down.
        private func textLine(near y: CGFloat, in pdfView: PDFView) -> PDFSelection? {
            for dy in stride(from: 0.0, through: 60.0, by: 6.0) {
                for sign in [1.0, -1.0] as [CGFloat] {
                    let p = CGPoint(x: pageWidth / 2, y: y + dy * sign)
                    guard let page = pdfView.page(for: p, nearest: true) else { continue }
                    let pp = pdfView.convert(p, to: page)
                    if let sel = page.selectionForLine(at: pp), let s = sel.string, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                        return sel
                    }
                }
            }
            return nil
        }

        private static func recognize(_ image: UIImage) async -> String {
            guard let cg = image.cgImage else { return "" }
            // Ink is dark on transparent; flatten onto white so Vision sees paper.
            let renderer = UIGraphicsImageRenderer(size: image.size)
            let flat = renderer.image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: image.size))
                UIImage(cgImage: cg, scale: image.scale, orientation: .up).draw(at: .zero)
            }
            var request = RecognizeTextRequest()
            request.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
            request.recognitionLevel = .accurate
            guard let data = flat.pngData(), let obs = try? await request.perform(on: data) else { return "" }
            return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
    }
}

struct InkImage: View {
    let drawing: PKDrawing
    let maxWidth: CGFloat

    var body: some View {
        let b = drawing.bounds.insetBy(dx: -2, dy: -2)
        let scale = min(1, maxWidth / max(b.width, 1))
        Image(uiImage: drawing.image(from: b, scale: 2))
            .resizable()
            .frame(width: b.width * scale, height: b.height * scale)
    }
}

/// A brush-script face for handwritten questions. Kaiti is an on-demand system font on iOS, so it is fetched on
/// first launch; until it arrives the question falls back to the serif.
enum HandFont {
    private static let name = "STKaitiSC-Regular"
    nonisolated(unsafe) private static var ready = UIFont(name: name, size: 12) != nil

    static func font(size: CGFloat) -> Font {
        ready ? .custom(name, size: size) : .system(size: size * 0.85, design: .serif).italic()
    }

    static func prepare() {
        guard !ready else { return }
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name] as CFDictionary)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([desc] as CFArray, nil) { state, _ in
            if state == .didFinish {
                DispatchQueue.main.async { ready = UIFont(name: name, size: 12) != nil }
            }
            return true
        }
    }
}
