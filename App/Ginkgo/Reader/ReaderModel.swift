import GinkgoAI
import GinkgoCore
import Observation
import OSLog
import PDFKit
import PencilKit
import SwiftData
import SwiftUI

/// Reading mode keeps annotations nearly invisible; review mode opens every note.
enum ViewMode: String, CaseIterable, Identifiable {
    case reading, review
    var id: String { rawValue }
    var label: String { self == .reading ? "阅读" : "回顾" }
}

/// Screen geometry of one annotation, in reader coordinates (the PDF view's coordinate space).
struct NoteGeometry {
    var lines: [CGRect]
    var first: CGRect { lines.first ?? .zero }
    var union: CGRect { lines.reduce(CGRect.null) { $0.union($1) } }
}

/// A highlight or rule in progress.
struct MarkPreview {
    var lines: [CGRect]
    var style: MarkStyle
    var color: HighlightColor
    var selection: PDFSelection
}

/// What the question sheet is asking about.
enum AskTarget: Identifiable {
    case selection(PDFSelection)
    case annotation(UUID)
    /// A further question on a note that already has an answer.
    case followUp(UUID)

    var id: String {
        switch self {
        case .selection(let s): "sel-\(s.string?.hashValue ?? 0)"
        case .annotation(let id): id.uuidString
        case .followUp(let id): "more-\(id.uuidString)"
        }
    }
}

/// State of one open book: its annotations, where they are on screen, and the AI requests in flight.
@Observable
final class ReaderModel {
    static let log = Logger(subsystem: "com.kenjia.ginkgo", category: "ai")
    let book: Book
    let document: PDFDocument
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored var tasks: [UUID: Task<Void, Never>] = [:]
    /// What each note is waiting for from the AI beyond its first answer (key expressions, analysis, a follow-up).
    var busy: [UUID: NoteActivity] = [:]
    @ObservationIgnored let pageInk = PageInk()

    private(set) var annotations: [AnnotationRecord] = []
    var mode: ViewMode = .reading
    var chromeVisible = true

    private(set) var geometry: [UUID: NoteGeometry] = [:]
    private(set) var pageFrames: [CGRect] = []
    var cardHeights: [UUID: CGFloat] = [:]

    private(set) var selection: PDFSelection?
    private(set) var selectionRect: CGRect?
    /// Line rectangles of the selection, drawn by us in writing mode where PDFKit does not show it.
    private(set) var selectionLines: [CGRect] = []
    /// The annotation whose menu is showing (tapped highlight) or whose card is active.
    var focused: UUID?
    /// Notes opened in reading mode, or folded away in review mode.
    var peeked: Set<UUID> = []
    var collapsed: Set<UUID> = []
    /// A note too long for its floating card, shown in full in the side column (or side panel in narrow windows).
    var expanded: UUID?
    var asking: AskTarget?
    var showSettings = false
    var showNotes = false
    /// The scratch sheet beside the book. While it is open, undo and redo act on it.
    var showScratch = false {
        didSet { scratchToggled() }
    }
    var scratchWidth: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "scratch.width") as? Double ?? 360) {
        didSet { UserDefaults.standard.set(Double(scratchWidth), forKey: "scratch.width") }
    }
    @ObservationIgnored let scratchUndo = UndoManager()
    @ObservationIgnored weak var scratchCanvas: ScratchCanvasView?
    /// The Pencil's tool. Nil: the Pencil selects text like a finger. Fingers never draw (except the mouse in the
    /// simulator, which draws whenever a tool is chosen).
    var tool: PenTool? = ToolSettings.tool {
        didSet {
            ToolSettings.tool = tool
            if let oldValue, oldValue != tool { previousTool = oldValue }
            pageInk.toolChanged()
            applyTouchRules()
            if tool == nil { pageInk.saveAll() }
            paletteAt = nil
        }
    }
    /// For the Pencil's "switch to previous tool" double-tap.
    @ObservationIgnored private var previousTool: PenTool?
    var markColor = ToolSettings.markColor { didSet { ToolSettings.markColor = markColor; pageInk.toolChanged() } }
    var inkColor = ToolSettings.inkColor { didSet { ToolSettings.inkColor = inkColor; pageInk.toolChanged() } }
    var underlineStyle = ToolSettings.underlineStyle { didSet { ToolSettings.underlineStyle = underlineStyle } }
    var highlighterFreehand = ToolSettings.highlighterFreehand {
        didSet { ToolSettings.highlighterFreehand = highlighterFreehand; pageInk.toolChanged() }
    }
    /// The mark being drawn: lines in reader coordinates, shown live under the Pencil.
    var markPreview: MarkPreview?
    /// Whether the current tool marks text live (so the page canvas stays out of the way).
    var marksLive: Bool { tool?.snapsToText(freehand: highlighterFreehand) ?? false }
    /// Fingers use the tool too (no Pencil at hand). Follows the system's "Only Draw with Apple Pencil" until
    /// the reader flips it in the tray.
    var fingersDraw = ToolSettings.fingersDraw {
        didSet { ToolSettings.fingersDraw = fingersDraw; applyTouchRules() }
    }

    func applyTouchRules() {
        (pdfView as? ReaderPDFView)?.reserveTouches(tool: tool != nil, fingersDraw: fingersDraw)
        pageInk.toolChanged()
    }

    var showToolHint = !ToolSettings.seenHint
    /// Mirrors the undo manager for the tray's buttons.
    var canUndo = false
    var canRedo = false
    /// Where a Pencil squeeze opened the tool palette, in reader coordinates.
    var paletteAt: CGPoint?
    /// Pencil hover position, for the tool preview ring.
    var hoverPoint: CGPoint?
    /// The selection came from a lasso; we draw it ourselves since PDFKit may not show selections set in code.
    private(set) var selectionFromPencil = false

    /// Tapping the current tool puts it down; tapping another picks it up.
    func select(_ tool: PenTool) {
        self.tool = self.tool == tool ? nil : tool
        dismissToolHint()
    }

    func dismissToolHint() {
        guard showToolHint else { return }
        showToolHint = false
        ToolSettings.seenHint = true
    }

    /// Double-tap on the Pencil barrel, following the system setting.
    func pencilTapped(_ action: UIPencilPreferredAction) {
        switch action {
        case .switchEraser: tool = tool == .eraser ? (previousTool ?? .pen) : .eraser
        case .switchPrevious: tool = previousTool ?? (tool == nil ? .highlighter : nil)
        case .showColorPalette, .showContextualPalette: paletteAt = paletteAt == nil ? hoverPoint ?? defaultPalettePoint : nil
        default: break
        }
    }

    /// Squeeze on Apple Pencil Pro: the tool palette at the tip, or the system's other squeeze actions.
    func pencilSqueezed(at point: CGPoint?, action: UIPencilPreferredAction) {
        switch action {
        case .showContextualPalette, .showColorPalette: paletteAt = paletteAt == nil ? (point ?? defaultPalettePoint) : nil
        case .switchEraser, .switchPrevious: pencilTapped(action)
        default: break
        }
    }

    private var defaultPalettePoint: CGPoint {
        CGPoint(x: (pdfView?.bounds.width ?? 600) / 2, y: (pdfView?.bounds.height ?? 800) / 3)
    }

    /// The selection a lasso made: shows the selection menu.
    func selectFromPencil(_ selection: PDFSelection) {
        pdfView?.currentSelection = selection
        selectionChanged(selection)
        selectionFromPencil = true
    }

    /// The eraser passed over a point: remove plain marks there (notes keep their answers; delete those from the card).
    func eraseMark(at point: CGPoint) {
        guard let id = annotation(at: point), let record = annotation(id), !record.hasNote, record.kind != .ink else { return }
        withAnimation(.smooth(duration: 0.15)) { delete(id) }
    }

    init(book: Book, document: PDFDocument, context: ModelContext) {
        self.book = book
        self.document = document
        self.context = context
        reload()
        pageInk.model = self
    }

    // MARK: - Annotations

    func reload() {
        annotations = (book.annotations ?? []).sorted {
            guard let a = $0.anchor, let b = $1.anchor else { return $0.createdAt < $1.createdAt }
            return a.readingOrder < b.readingOrder
        }
        recompute()
    }

    func annotation(_ id: UUID) -> AnnotationRecord? { annotations.first { $0.id == id } }

    var notes: [AnnotationRecord] { annotations.filter(\.hasNote) }

    func isOpen(_ id: UUID) -> Bool {
        switch mode {
        case .review: !collapsed.contains(id)
        case .reading: peeked.contains(id)
        }
    }

    func toggle(_ id: UUID) {
        switch mode {
        case .review: if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        case .reading: if peeked.contains(id) { peeked.remove(id) } else { peeked.insert(id) }
        }
        if !isOpen(id), expanded == id { expanded = nil }
        focused = isOpen(id) ? id : nil
    }

    /// Opens a long note in the side column.
    func expand(_ id: UUID) {
        peeked.insert(id)
        collapsed.remove(id)
        expanded = id
        focused = id
    }

    /// Closes floating cards and the side column opened while reading. Returns false if nothing was open.
    @discardableResult
    func foldAll() -> Bool {
        guard expanded != nil || (mode == .reading && !peeked.isEmpty) else { return false }
        expanded = nil
        if mode == .reading { peeked.removeAll() }
        focused = nil
        return true
    }

    @discardableResult
    func highlight(_ selection: PDFSelection, color: HighlightColor, style: MarkStyle = .highlight) -> AnnotationRecord? {
        guard let anchor = Self.anchor(for: selection, in: document) else { return nil }
        let record = AnnotationRecord(kind: .highlight, anchor: anchor, color: color)
        if style != .highlight { record.styleRaw = style.rawValue }
        record.book = book
        context.insert(record)
        registerRemoval(of: record.id, name: style == .highlight ? "高亮" : "划线")
        // Only end the selection this highlight came from (a margin note may land while another is showing).
        if selection === self.selection { clearSelection() }
        reload()
        return record
    }

    func recolor(_ id: UUID, _ color: HighlightColor) {
        guard let record = annotation(id), record.color != color else { return }
        let old = record.color
        record.colorRaw = color.rawValue
        registerUndo("换颜色") { $0.recolor(id, old) }
        reload()
    }

    func delete(_ id: UUID) {
        cancelTask(id)
        if let record = annotation(id) {
            let snapshot = AnnotationSnapshot(record)
            registerUndo("删除批注") { $0.restore(snapshot) }
            context.delete(record)
        }
        focused = nil
        peeked.remove(id)
        if expanded == id { expanded = nil }
        try? context.save()
        // The relationship array updates on save; drop the record locally right away.
        annotations.removeAll { $0.id == id }
        geometry[id] = nil
    }

    /// Scrolls to an annotation and opens its note.
    func reveal(_ id: UUID) {
        guard let pdfView, case .pdf(let a)? = annotation(id)?.anchor, let page = document.page(at: a.pageIndex) else { return }
        let target = a.bounds.isNull ? page.bounds(for: pdfView.displayBox) : a.bounds.insetBy(dx: 0, dy: -120)
        pdfView.go(to: target, on: page)
        focused = id
        if annotation(id)?.hasNote == true { peeked.insert(id); collapsed.remove(id) }
        DispatchQueue.main.async { self.recompute() }
    }

    // MARK: - Ink

    /// Free ink on a page (not interpreted as a gesture), stored as one record per page.
    func inkDrawing(page: Int) -> PKDrawing? {
        inkRecord(page: page)?.inkData.flatMap { try? PKDrawing(data: $0) }
    }

    func saveInk(_ drawing: PKDrawing, page: Int) {
        let existing = inkRecord(page: page)
        if drawing.strokes.isEmpty {
            if let existing { context.delete(existing) }
            return
        }
        let record = existing ?? {
            let r = AnnotationRecord(kind: .ink, anchor: .pdf(PDFAnchor(pageIndex: page, rects: [], quote: "")))
            r.book = book
            context.insert(r)
            return r
        }()
        record.inkData = drawing.dataRepresentation()
    }

    private func inkRecord(page: Int) -> AnnotationRecord? {
        (book.annotations ?? []).first { record in
            guard record.kind == .ink, case .pdf(let a)? = record.anchor else { return false }
            return a.pageIndex == page
        }
    }

    /// A question written by hand beside a line: keep the ink on the card and ask about the line.
    func addHandwrittenQuestion(_ ink: PKDrawing, recognized: String, on line: PDFSelection) {
        guard let record = highlight(line, color: .blue) else { return }
        record.inkData = ink.dataRepresentation()
        let text = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            record.question = "（没认出手写内容）"
            run(.explain, on: record.id)
            record.question = "（没认出手写内容）"
        } else {
            run(.handwritten(text), on: record.id)
        }
    }

    // MARK: - Selection

    func selectionChanged(_ selection: PDFSelection?) {
        let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.selection = text.isEmpty ? nil : selection
        selectionFromPencil = false
        if self.selection != nil { focused = nil }
        recomputeSelectionRect()
    }

    func clearSelection() {
        pdfView?.clearSelection()
        selection = nil
        selectionRect = nil
        selectionLines = []
        selectionFromPencil = false
    }

    // MARK: - Geometry

    /// Converts every anchor and visible page into reader coordinates. Called on scroll, zoom and layout.
    func recompute() {
        guard let pdfView else { return }
        var out: [UUID: NoteGeometry] = [:]
        let visible = Set((pdfView.visiblePages).compactMap { document.index(for: $0) })
        for record in annotations {
            guard case .pdf(let a)? = record.anchor, visible.contains(a.pageIndex),
                  let page = document.page(at: a.pageIndex) else { continue }
            out[record.id] = NoteGeometry(lines: a.rects.map { pdfView.convert($0, from: page) })
        }
        geometry = out
        pageFrames = pdfView.visiblePages.map { pdfView.convert($0.bounds(for: pdfView.displayBox), from: $0) }
        recomputeSelectionRect()
    }

    private func recomputeSelectionRect() {
        guard let pdfView, let selection, let page = selection.pages.first else {
            selectionRect = nil
            selectionLines = []
            return
        }
        selectionRect = pdfView.convert(selection.bounds(for: page), from: page)
        selectionLines = selection.selectionsByLine().filter { $0.pages.first == page }
            .map { pdfView.convert($0.bounds(for: page), from: page) }
    }

    /// The annotation under a point in reader coordinates, if any.
    func annotation(at point: CGPoint) -> UUID? {
        for (id, g) in geometry where g.lines.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
            return id
        }
        return nil
    }

    // MARK: - Helpers

    static func anchor(for selection: PDFSelection, in document: PDFDocument) -> GinkgoCore.Anchor? {
        guard let page = selection.pages.first, let quote = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quote.isEmpty else { return nil }
        let lines = selection.selectionsByLine().filter { $0.pages.first == page }
        let rects = lines.map { $0.bounds(for: page) }.filter { $0.width > 0.5 && $0.height > 0.5 }
        let range = selection.range(at: 0, on: page)
        return .pdf(PDFAnchor(pageIndex: document.index(for: page),
                              rects: rects.isEmpty ? [selection.bounds(for: page)] : rects,
                              range: range.location == NSNotFound ? nil : range, quote: quote))
    }

    /// About a paragraph of page text on either side of the passage, for the prompt.
    func surroundingText(of anchor: GinkgoCore.Anchor) -> String {
        guard case .pdf(let a) = anchor, let range = a.range, let page = document.page(at: a.pageIndex),
              let text = page.string as NSString? else { return "" }
        let start = max(0, range.location - 400)
        let end = min(text.length, range.location + range.length + 400)
        return text.substring(with: NSRange(location: start, length: end - start))
            .replacingOccurrences(of: "\n", with: " ")
    }
}

extension HighlightColor {
    var fill: Color { Theme.highlight(self) }

    /// Adaptive ink for labels and connectors, separate from the marker on white PDF paper.
    var ink: Color { Theme.highlightInk(self) }

    var name: String {
        switch self {
        case .yellow: "黄"
        case .green: "绿"
        case .blue: "蓝"
        case .pink: "粉"
        case .violet: "紫"
        }
    }
}
