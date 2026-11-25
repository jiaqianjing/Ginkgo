import PencilKit
import SwiftUI

/// A sheet of paper beside the book for working things out: sums, sketches, half-formed thoughts that belong to
/// no passage. One per book, saved as the reader writes, with its own undo while it is open.
extension ReaderModel {
    func toggleScratch() {
        withAnimation(.smooth(duration: 0.3)) { showScratch.toggle() }
        paletteAt = nil
    }

    func scratchToggled() {
        if showScratch {
            DispatchQueue.main.async { [weak self] in self?.scratchCanvas?.becomeFirstResponder() }
        } else {
            saveScratch()
            DispatchQueue.main.async { [weak self] in self?.pdfView?.becomeFirstResponder() }
        }
        refreshUndoState()
        DispatchQueue.main.async { [weak self] in self?.recompute() }
    }

    var scratchDrawing: PKDrawing {
        book.scratchData.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
    }

    func scratchChanged(_ drawing: PKDrawing) {
        book.scratchData = drawing.strokes.isEmpty ? nil : drawing.dataRepresentation()
    }

    func saveScratch() {
        if let canvas = scratchCanvas { scratchChanged(canvas.drawing) }
        try? context.save()
    }

    /// Empties the sheet as one undoable step.
    func clearScratch() {
        guard let canvas = scratchCanvas, !canvas.drawing.strokes.isEmpty else { return }
        replaceScratch(with: PKDrawing(), name: String(localized: "清空草稿"))
    }

    private func replaceScratch(with drawing: PKDrawing, name: String) {
        guard let canvas = scratchCanvas else { return }
        let old = canvas.drawing
        canvas.drawing = drawing
        scratchChanged(drawing)
        scratchUndo.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.replaceScratch(with: old, name: name) }
        }
        scratchUndo.setActionName(name)
        refreshUndoState()
    }
}

// MARK: Panel

/// The scratch sheet: a paper panel on the right. Wide windows put it beside the page; narrow ones float it over.
struct ScratchSheet: View {
    @Bindable var model: ReaderModel
    let maxWidth: CGFloat
    @State private var dragStart: CGFloat?

    var body: some View {
        // iOS 26's back swipe works anywhere in the content, so a stroke drawn left to right would leave the book.
        VStack(spacing: 0) {
            BackSwipeBlocker().frame(width: 0, height: 0)
            HStack(spacing: Theme.Space.small) {
                Label("草稿", systemImage: "pencil.and.scribble")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Menu {
                    Button("清空草稿", systemImage: "trash", role: .destructive) { model.clearScratch() }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: Theme.Tray.button, height: Theme.Tray.button)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("草稿选项")
                Button { model.toggleScratch() } label: {
                    Image(systemName: "xmark")
                        .frame(width: Theme.Tray.button, height: Theme.Tray.button)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("收起草稿")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryInk)
            .padding(.leading, Theme.Space.generous)
            .padding(.trailing, Theme.Space.compact)
            .padding(.vertical, Theme.Space.tiny)
            Rectangle().fill(Theme.rule).frame(height: Theme.hairline)
            ScratchCanvas(model: model)
        }
        .background(Theme.paper)
        .overlay(alignment: .leading) { resizeHandle }
    }

    /// Drag the left edge to make the sheet wider or narrower.
    private var resizeHandle: some View {
        Capsule()
            .fill(Theme.rule)
            .frame(width: 4, height: 44)
            .frame(width: 24, height: 120)
            .contentShape(Rectangle())
            .offset(x: -12)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? model.scratchWidth
                        dragStart = start
                        model.scratchWidth = min(max(start - value.translation.width, 280), maxWidth)
                    }
                    .onEnded { _ in dragStart = nil; model.recompute() }
            )
            .accessibilityLabel("调整草稿宽度")
    }
}

// MARK: Canvas

/// PencilKit canvas with the book's undo kept out: its strokes register on the scratch sheet's own undo manager.
final class ScratchCanvasView: PKCanvasView {
    weak var model: ReaderModel?
    let grid = UIView()

    override var undoManager: UndoManager? { model?.scratchUndo ?? super.undoManager }
    override var canBecomeFirstResponder: Bool { true }

    /// The paper grows as the reader writes further down: always at least a screen below the last stroke.
    func fitContent() {
        guard bounds.height > 0 else { return }
        // An empty drawing's bounds are the null rect, whose maxY is infinite.
        let bottom = drawing.strokes.isEmpty ? 0 : drawing.bounds.maxY
        let height = max(bounds.height * 1.5, bottom + bounds.height)
        if abs(contentSize.height - height) > 1 || contentSize.width != bounds.width {
            contentSize = CGSize(width: bounds.width, height: height)
        }
        grid.frame = CGRect(origin: .zero, size: contentSize)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitContent()
        sendSubviewToBack(grid)
    }
}

struct ScratchCanvas: UIViewRepresentable {
    let model: ReaderModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> ScratchCanvasView {
        let canvas = ScratchCanvasView()
        canvas.model = model
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.grid.backgroundColor = UIColor(patternImage: Self.gridImage)
        canvas.grid.isUserInteractionEnabled = false
        canvas.insertSubview(canvas.grid, at: 0)
        canvas.drawing = model.scratchDrawing
        canvas.delegate = context.coordinator
        // A new canvas: undo steps left from an earlier one (if it hasn't been dismantled yet) no longer apply.
        model.scratchUndo.removeAllActions()
        model.scratchCanvas = canvas
        configure(canvas)
        return canvas
    }

    func updateUIView(_ canvas: ScratchCanvasView, context: Context) { configure(canvas) }

    /// PencilKit's undo steps point at this canvas, so they go with it; otherwise undoing one later would change
    /// a canvas nobody sees and save its stale drawing over the real one.
    static func dismantleUIView(_ canvas: ScratchCanvasView, coordinator: Coordinator) {
        let model = coordinator.model
        guard model.scratchCanvas === canvas else { return }
        model.scratchChanged(canvas.drawing)
        model.scratchUndo.removeAllActions()
        model.scratchCanvas = nil
        model.refreshUndoState()
    }

    /// The tray's tool and colours, so the sheet writes like the page does. With no tool chosen it is a pen:
    /// a scratch sheet is for writing.
    private func configure(_ canvas: PKCanvasView) {
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = model.fingersDraw ? .anyInput : .pencilOnly
        #endif
        switch model.tool {
        case .highlighter?:
            canvas.tool = PKInkingTool(.marker, color: UIColor(model.markColor.fill).withAlphaComponent(0.5), width: 14)
        case .underline?:
            canvas.tool = PKInkingTool(.monoline, color: UIColor(Theme.markLine(model.markColor)), width: 2)
        case .lasso?:
            canvas.tool = PKLassoTool()
        case .eraser?:
            canvas.tool = PKEraserTool(.bitmap)
        default:
            canvas.tool = PKInkingTool(.pen, color: UIColor(model.inkColor.color), width: 2.4)
        }
    }

    /// A faint dot every 24 points, readable in light and dark.
    private static let gridImage: UIImage = {
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.5, alpha: 0.35).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 11, y: 11, width: 2, height: 2))
        }
    }()

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let model: ReaderModel
        init(model: ReaderModel) { self.model = model }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard canvasView === model.scratchCanvas else { return }
            model.scratchChanged(canvasView.drawing)
            (canvasView as? ScratchCanvasView)?.fitContent()
            model.refreshUndoState()
        }
    }
}
