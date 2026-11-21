import GinkgoAI
import GinkgoCore
import PDFKit
import PencilKit
import SwiftUI
import Vision

/// One PencilKit canvas per PDF page, attached through PDFKit's overlay provider, so ink scrolls and zooms with
/// the page. A pause after writing interprets the new strokes: an underline becomes a highlight, a loop selects
/// text, writing in the page margin becomes a handwritten question; anything else stays as ink.
final class PageInk: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    weak var model: ReaderModel?
    private var canvases: [Int: PKCanvasView] = [:]
    private var processed: [Int: Int] = [:]
    private var pending: [Int: DispatchWorkItem] = [:]
    private var applyingChange = false

    var drawingEnabled = false {
        didSet { canvases.values.forEach(configure) }
    }

    // MARK: Overlay provider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let model, let index = view.document?.index(for: page) else { return nil }
        let canvas = canvases[index] ?? PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = self
        canvas.tag = index
        if canvases[index] == nil {
            applyingChange = true
            canvas.drawing = model.inkDrawing(page: index) ?? PKDrawing()
            applyingChange = false
            processed[index] = canvas.drawing.strokes.count
        }
        canvases[index] = canvas
        configure(canvas)
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        model?.saveInk(canvas.drawing, page: canvas.tag)
        canvases[canvas.tag] = nil
    }

    private func configure(_ canvas: PKCanvasView) {
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput  // mouse in the simulator; Pencil only on a device
        #else
        canvas.drawingPolicy = .pencilOnly
        #endif
        canvas.isUserInteractionEnabled = drawingEnabled
        canvas.tool = PKInkingTool(.pen, color: UIColor(red: 0.18, green: 0.2, blue: 0.26, alpha: 1), width: 2.2)
    }

    func saveAll() {
        for (index, canvas) in canvases { model?.saveInk(canvas.drawing, page: index) }
    }

    // MARK: Interpreting strokes

    func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
        guard !applyingChange else { return }
        let index = canvas.tag
        pending[index]?.cancel()
        let work = DispatchWorkItem { [weak self, weak canvas] in
            guard let self, let canvas else { return }
            self.interpret(canvas, page: index)
        }
        pending[index] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func interpret(_ canvas: PKCanvasView, page index: Int) {
        guard let model, let page = model.document.page(at: index) else { return }
        let strokes = canvas.drawing.strokes
        let start = min(processed[index] ?? 0, strokes.count)
        let fresh = Array(strokes[start...])
        guard !fresh.isEmpty else { return }

        let space = PageSpace(page: page, canvas: canvas.bounds.size, box: model.pdfView?.displayBox ?? .cropBox)
        let lines = space.textLines()
        let column = lines.reduce(CGRect.null) { $0.union($1) }
        let intents = fresh.map { stroke in
            StrokeClassifier.classify(points: stroke.path.map { $0.location.applying(stroke.transform) },
                                      textLines: lines, textColumn: column)
        }

        var keep: [PKStroke] = Array(strokes[..<start])
        // Several strokes written in the margin together are one handwritten question.
        let marginStrokes = zip(fresh, intents).filter { if case .marginNote = $0.1 { return true }; return false }.map(\.0)
        if !marginStrokes.isEmpty, case .marginNote(let line)? = intents.first(where: { if case .marginNote = $0 { return true }; return false }) {
            let ink = PKDrawing(strokes: marginStrokes)
            if let selection = page.selectionForLine(at: space.toPage(CGPoint(x: line.midX, y: line.midY))) {
                Task { @MainActor in
                    let text = await HandwritingReader.read(ink)
                    model.addHandwrittenQuestion(ink, recognized: text, on: selection)
                }
            }
        }
        for (stroke, intent) in zip(fresh, intents) {
            switch intent {
            case .underline(let line, let x0, let x1):
                let a = space.toPage(CGPoint(x: x0 + 1, y: line.midY)), b = space.toPage(CGPoint(x: x1 - 1, y: line.midY))
                if let sel = page.selection(from: a, to: b), sel.string?.isEmpty == false {
                    model.highlight(sel, color: model.penHighlightColor)
                } else {
                    keep.append(stroke)
                }
            case .circle(let bounds):
                if let sel = page.selection(for: space.toPage(bounds)), sel.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    model.pdfView?.currentSelection = sel
                    model.selectionChanged(sel)
                } else {
                    keep.append(stroke)
                }
            case .marginNote:
                break
            case .ink:
                keep.append(stroke)
            }
        }
        applyingChange = true
        canvas.drawing = PKDrawing(strokes: keep)
        applyingChange = false
        processed[index] = keep.count
        model.saveInk(canvas.drawing, page: index)
    }
}

#if DEBUG
extension PageInk {
    /// Draws an underline, a loop and a margin "?" on a page, as a finger would, to exercise `interpret`.
    func drawDemoStrokes(page index: Int) {
        guard let canvas = canvases[index], let page = model?.document.page(at: index) else { return }
        let lines = PageSpace(page: page, canvas: canvas.bounds.size, box: .cropBox).textLines()
        guard lines.count > 22 else { return }
        let column = lines.reduce(CGRect.null) { $0.union($1) }
        func stroke(_ pts: [CGPoint]) -> PKStroke {
            let path = PKStrokePath(controlPoints: pts.enumerated().map {
                PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) * 0.01, size: CGSize(width: 2.5, height: 2.5),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: Date())
            return PKStroke(ink: PKInk(.pen, color: .darkGray), path: path)
        }
        let u = lines[17]
        let underline = stride(from: u.minX + 4, through: u.minX + u.width * 0.6, by: 6).map { CGPoint(x: $0, y: u.maxY + 1) }
        let c = lines[21]
        let loop = (0...36).map { i -> CGPoint in
            let a = Double(i) / 36 * 2 * .pi
            return CGPoint(x: c.minX + 70 + cos(a) * 62, y: c.midY + sin(a) * 13)
        }
        let m = lines[9]
        let x = column.maxX + 14, y = m.minY - 4
        let question = (0...24).map { i -> CGPoint in
            let t = Double(i) / 24
            if t < 0.7 { let a = -Double.pi * 0.9 + t / 0.7 * Double.pi * 1.4; return CGPoint(x: x + 8 + cos(a) * 7, y: y + 7 + sin(a) * 7) }
            return CGPoint(x: x + 9, y: y + 14 + (t - 0.7) * 20)
        }
        let dot = [CGPoint(x: x + 9, y: y + 24), CGPoint(x: x + 9.5, y: y + 24.5)]
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [stroke(underline), stroke(loop), stroke(question), stroke(dot)])
    }
}
#endif

/// Converts between a page overlay canvas (points, y down) and PDF page space (y up).
struct PageSpace {
    let page: PDFPage
    let canvas: CGSize
    let box: PDFDisplayBox

    private var bounds: CGRect { page.bounds(for: box) }
    private var sx: CGFloat { bounds.width / max(canvas.width, 1) }
    private var sy: CGFloat { bounds.height / max(canvas.height, 1) }

    func toPage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: bounds.minX + p.x * sx, y: bounds.maxY - p.y * sy)
    }

    func toPage(_ r: CGRect) -> CGRect {
        let a = toPage(CGPoint(x: r.minX, y: r.minY)), b = toPage(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func toCanvas(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - bounds.minX) / sx, y: (bounds.maxY - r.maxY) / sy, width: r.width / sx, height: r.height / sy)
    }

    /// Every text line on the page, in canvas space.
    func textLines() -> [CGRect] {
        guard let all = page.selection(for: bounds) else { return [] }
        return all.selectionsByLine().map { toCanvas($0.bounds(for: page)) }.filter { $0.width > 2 && $0.height > 2 }
    }
}

/// Reads handwriting with Vision (Chinese and English).
enum HandwritingReader {
    static func read(_ drawing: PKDrawing) async -> String {
        let bounds = drawing.bounds.insetBy(dx: -8, dy: -8)
        guard !bounds.isEmpty else { return "" }
        let image = drawing.image(from: bounds, scale: 3)
        // Ink is dark on transparent; flatten onto white so Vision sees paper.
        let flat = UIGraphicsImageRenderer(size: image.size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
        var request = RecognizeTextRequest()
        request.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
        request.recognitionLevel = .accurate
        guard let data = flat.pngData(), let observations = try? await request.perform(on: data) else { return "" }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

/// A canvas over the margin column (style A). Writing there, then pausing, asks about the line beside it.
struct MarginInkCanvas: UIViewRepresentable {
    let model: ReaderModel
    let layout: ReaderLayout

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = .pencilOnly
        #endif
        canvas.tool = PKInkingTool(.pen, color: UIColor(red: 0.18, green: 0.2, blue: 0.26, alpha: 1), width: 2.4)
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.model = model
        context.coordinator.pageWidth = layout.pageWidth
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var model: ReaderModel?
        var pageWidth: CGFloat = 0
        private var pending: DispatchWorkItem?

        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            pending?.cancel()
            guard !canvas.drawing.strokes.isEmpty else { return }
            let work = DispatchWorkItem { [weak self, weak canvas] in
                guard let self, let canvas else { return }
                self.finish(canvas)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
        }

        private func finish(_ canvas: PKCanvasView) {
            guard let model, let pdfView = model.pdfView else { return }
            let drawing = canvas.drawing
            canvas.drawing = PKDrawing()
            guard let line = textLine(near: drawing.bounds.minY + min(drawing.bounds.height, 30) / 2, in: pdfView) else { return }
            let local = drawing.transformed(using: CGAffineTransform(translationX: -drawing.bounds.minX, y: -drawing.bounds.minY))
            Task { @MainActor in
                let text = await HandwritingReader.read(drawing)
                model.addHandwrittenQuestion(local, recognized: text, on: line)
            }
        }

        /// The text line at the given height of the reader, searching a little up and down.
        private func textLine(near y: CGFloat, in pdfView: PDFView) -> PDFSelection? {
            for dy in stride(from: 0.0, through: 60.0, by: 6.0) {
                for sign in [1.0, -1.0] as [CGFloat] {
                    let p = CGPoint(x: pageWidth / 2, y: y + dy * sign)
                    guard let page = pdfView.page(for: p, nearest: true) else { continue }
                    if let sel = page.selectionForLine(at: pdfView.convert(p, to: page)),
                       sel.string?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                        return sel
                    }
                }
            }
            return nil
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
