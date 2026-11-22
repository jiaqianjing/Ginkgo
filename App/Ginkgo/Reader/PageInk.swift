import GinkgoAI
import GinkgoCore
import PDFKit
import PencilKit
import SwiftUI
import Vision

/// One PencilKit canvas per PDF page, attached through PDFKit's overlay provider, so ink scrolls and zooms with
/// the page. New strokes are interpreted by the tool that drew them (told apart by ink type): highlighter and
/// underline strokes snap to the text and become marks, a lasso selects text, and pen writing in the page margin
/// becomes a handwritten question. Other pen strokes stay as ink.
final class PageInk: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    weak var model: ReaderModel?
    private var canvases: [Int: PKCanvasView] = [:]
    private var processed: [Int: Int] = [:]
    private var pending: [Int: DispatchWorkItem] = [:]
    private var applyingChange = false

    /// Re-reads the model's tool and colours onto every canvas.
    func toolChanged() { canvases.values.forEach(configure) }

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
        canvas.isScrollEnabled = false
        let tool = model?.tool
        canvas.isUserInteractionEnabled = tool != nil
        switch tool {
        case .highlighter?:
            canvas.tool = PKInkingTool(.marker, color: UIColor(model?.markColor.fill ?? .yellow).withAlphaComponent(0.5), width: 14)
        case .underline?:
            canvas.tool = PKInkingTool(.monoline, color: UIColor(Theme.markLine(model?.markColor ?? .yellow)), width: 1.6)
        case .lasso?:
            canvas.tool = PKInkingTool(.pencil, color: UIColor(Theme.accent).withAlphaComponent(0.7), width: 2)
        case .eraser?:
            canvas.tool = PKEraserTool(.vector)
        default:
            canvas.tool = PKInkingTool(.pen, color: UIColor(model?.inkColor.color ?? Theme.penGraphite), width: 2.2)
        }
        installEraserTracking(on: canvas, active: tool == .eraser)
    }

    /// PencilKit's eraser only touches ink; this follows it so plain marks under its path are erased too.
    private func installEraserTracking(on canvas: PKCanvasView, active: Bool) {
        let existing = canvas.gestureRecognizers?.first { $0.name == "ginkgo.eraser" }
        if !active { existing?.isEnabled = false; return }
        if let existing { existing.isEnabled = true; return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(erasing(_:)))
        pan.name = "ginkgo.eraser"
        pan.delegate = self
        pan.cancelsTouchesInView = false
        #if !targetEnvironment(simulator)
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        #endif
        canvas.addGestureRecognizer(pan)
    }

    @objc private func erasing(_ g: UIPanGestureRecognizer) {
        guard let model, let pdfView = model.pdfView, let view = g.view else { return }
        model.eraseMark(at: view.convert(g.location(in: view), to: pdfView))
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
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
        // Handwriting needs a pause to finish a word; marks and lassos can act almost at once.
        let last = canvas.drawing.strokes.last.flatMap { PenTool(inkType: $0.ink.inkType) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (last == .pen ? 1.1 : 0.25), execute: work)
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
        func points(_ stroke: PKStroke) -> [CGPoint] { stroke.path.map { $0.location.applying(stroke.transform) } }
        func selection(_ span: StrokeSnapping.Span) -> PDFSelection? {
            guard let sel = page.selection(from: space.toPage(span.start), to: space.toPage(span.end)),
                  sel.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
            return sel
        }

        var keep: [PKStroke] = Array(strokes[..<start])
        var penStrokes: [PKStroke] = []
        for stroke in fresh {
            switch PenTool(inkType: stroke.ink.inkType) {
            case .highlighter?:
                if let span = StrokeSnapping.highlight(points: points(stroke), textLines: lines), let sel = selection(span) {
                    model.highlight(sel, color: model.markColor)
                } else {
                    keep.append(stroke)  // a marker stroke off the text stays as marker ink
                }
            case .underline?:
                if let span = StrokeSnapping.underline(points: points(stroke), textLines: lines), let sel = selection(span) {
                    model.highlight(sel, color: model.markColor, style: model.underlineStyle)
                } else {
                    keep.append(stroke)
                }
            case .lasso?:
                // A lasso never stays on the page: it either selects text or disappears.
                if let box = StrokeSnapping.lasso(points: points(stroke), textLines: lines),
                   let sel = page.selection(for: space.toPage(box)),
                   sel.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    model.selectFromPencil(sel)
                }
            default:
                penStrokes.append(stroke)
            }
        }
        // Pen: strokes in the page margin together are one handwritten question; the rest stay as ink.
        var marginLine: CGRect?
        var marginStrokes: [PKStroke] = []
        for stroke in penStrokes {
            if case .marginNote(let line) = StrokeClassifier.classify(points: points(stroke), textLines: lines, textColumn: column) {
                marginLine = marginLine ?? line
                marginStrokes.append(stroke)
            } else {
                keep.append(stroke)
            }
        }
        if let line = marginLine {
            let ink = PKDrawing(strokes: marginStrokes)
            if let selection = page.selectionForLine(at: space.toPage(CGPoint(x: line.midX, y: line.midY))) {
                Task { @MainActor in
                    let text = await HandwritingReader.read(ink)
                    model.addHandwrittenQuestion(ink, recognized: text, on: selection)
                }
            } else {
                keep.append(contentsOf: marginStrokes)
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
    /// Draws an underline (underline tool), a loop (lasso), a highlighter pass and a margin "?" (pen).
    func drawDemoStrokes(page index: Int) {
        guard let canvas = canvases[index], let page = model?.document.page(at: index) else { return }
        let lines = PageSpace(page: page, canvas: canvas.bounds.size, box: .cropBox).textLines()
        guard lines.count > 22 else { return }
        let column = lines.reduce(CGRect.null) { $0.union($1) }
        func stroke(_ pts: [CGPoint], _ inkType: PKInk.InkType = .pen) -> PKStroke {
            let path = PKStrokePath(controlPoints: pts.enumerated().map {
                PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) * 0.01, size: CGSize(width: 2.5, height: 2.5),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: Date())
            return PKStroke(ink: PKInk(inkType, color: .darkGray), path: path)
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
        let h = lines[13]
        let marker = stride(from: h.minX + 10, through: h.minX + h.width * 0.5, by: 6).map { CGPoint(x: $0, y: h.midY) }
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [stroke(underline, .monoline), stroke(loop, .pencil),
                                                                      stroke(marker, .marker), stroke(question), stroke(dot)])
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
