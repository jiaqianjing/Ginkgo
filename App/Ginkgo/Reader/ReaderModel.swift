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

/// What the question sheet is asking about.
enum AskTarget: Identifiable {
    case selection(PDFSelection)
    case annotation(UUID)

    var id: String {
        switch self {
        case .selection(let s): "sel-\(s.string?.hashValue ?? 0)"
        case .annotation(let id): id.uuidString
        }
    }
}

/// State of one open book: its annotations, where they are on screen, and the AI requests in flight.
@Observable
final class ReaderModel {
    private static let log = Logger(subsystem: "com.kenjia.ginkgo", category: "ai")
    let book: Book
    let document: PDFDocument
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
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
    var asking: AskTarget?
    var showSettings = false
    var showNotes = false
    /// Writing mode: Pencil (or the mouse in the simulator) draws on the page instead of selecting text.
    var penOn = false {
        didSet {
            pdfView?.isInMarkupMode = penOn
            pageInk.drawingEnabled = penOn
            if !penOn { pageInk.saveAll() }
            clearSelection()
        }
    }
    /// Colour used when an underline stroke becomes a highlight.
    var penHighlightColor: HighlightColor = .yellow

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
        focused = isOpen(id) ? id : nil
    }

    @discardableResult
    func highlight(_ selection: PDFSelection, color: HighlightColor) -> AnnotationRecord? {
        guard let anchor = Self.anchor(for: selection, in: document) else { return nil }
        let record = AnnotationRecord(kind: .highlight, anchor: anchor, color: color)
        record.book = book
        context.insert(record)
        // Only end the selection this highlight came from (a margin note may land while another is showing).
        if selection === self.selection { clearSelection() }
        reload()
        return record
    }

    func recolor(_ id: UUID, _ color: HighlightColor) {
        annotation(id)?.colorRaw = color.rawValue
        reload()
    }

    func delete(_ id: UUID) {
        tasks[id]?.cancel()
        if let record = annotation(id) { context.delete(record) }
        focused = nil
        peeked.remove(id)
        try? context.save()
        // The relationship array updates on save; drop the record locally right away.
        annotations.removeAll { $0.id == id }
        geometry[id] = nil
    }

    /// Runs an AI task on the selection, creating a highlight to hang the note on.
    func run(_ task: AITask, on selection: PDFSelection, color: HighlightColor = .yellow) {
        guard let record = highlight(selection, color: color) else { return }
        run(task, on: record.id)
    }

    /// Runs (or re-runs) an AI task on an existing annotation; the answer streams into its card.
    func run(_ task: AITask, on id: UUID) {
        guard let record = annotation(id), let anchor = record.anchor else { return }
        record.taskRaw = task.tag
        switch task {
        case .ask(let q), .handwritten(let q): record.question = q
        default: break
        }
        record.replyText = nil
        record.replyError = nil
        record.replyState = .pending
        peeked.insert(id)
        collapsed.remove(id)
        focused = id

        let settings = AISettings.shared
        let request = PromptBuilder.request(for: task, context: PassageContext(
            bookTitle: book.title, passage: anchor.quote, surrounding: surroundingText(of: anchor),
            readerLanguage: settings.readerLanguage))

        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            do {
                let (client, label) = try settings.client()
                record.replyModel = label
                var text = ""
                for try await chunk in client.stream(request) {
                    text += chunk
                    record.replyText = text
                    record.replyState = .streaming
                }
                record.replyState = .done
            } catch is CancellationError {
                return
            } catch {
                record.replyError = error.localizedDescription
                if let detail = (error as? AIError)?.detail { Self.log.error("AI request failed: \(detail, privacy: .public)") }
                record.replyState = .failed
            }
            try? self?.context.save()
        }
    }

    func retry(_ id: UUID) {
        guard let record = annotation(id) else { return }
        let task: AITask = switch record.taskRaw {
        case "translate": .translate
        case "explain": .explain
        case "handwritten": .handwritten(record.question ?? "")
        default: .ask(record.question ?? "")
        }
        run(task, on: id)
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
        if self.selection != nil { focused = nil }
        recomputeSelectionRect()
    }

    func clearSelection() {
        pdfView?.clearSelection()
        selection = nil
        selectionRect = nil
        selectionLines = []
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
    private func surroundingText(of anchor: GinkgoCore.Anchor) -> String {
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
