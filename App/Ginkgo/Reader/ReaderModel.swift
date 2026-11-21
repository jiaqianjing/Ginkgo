import GinkgoAI
import GinkgoCore
import Observation
import PDFKit
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
    let book: Book
    let document: PDFDocument
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    private(set) var annotations: [AnnotationRecord] = []
    var mode: ViewMode = .reading
    var chromeVisible = true

    private(set) var geometry: [UUID: NoteGeometry] = [:]
    private(set) var pageFrames: [CGRect] = []
    var cardHeights: [UUID: CGFloat] = [:]

    private(set) var selection: PDFSelection?
    private(set) var selectionRect: CGRect?
    /// The annotation whose menu is showing (tapped highlight) or whose card is active.
    var focused: UUID?
    /// Notes opened in reading mode, or folded away in review mode.
    var peeked: Set<UUID> = []
    var collapsed: Set<UUID> = []
    var asking: AskTarget?
    var showSettings = false

    init(book: Book, document: PDFDocument, context: ModelContext) {
        self.book = book
        self.document = document
        self.context = context
        reload()
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
        clearSelection()
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
        guard let pdfView, let selection, let page = selection.pages.first else { selectionRect = nil; return }
        selectionRect = pdfView.convert(selection.bounds(for: page), from: page)
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
    var fill: Color {
        switch self {
        case .yellow: Color(red: 1.0, green: 0.84, blue: 0.25)
        case .green: Color(red: 0.55, green: 0.85, blue: 0.45)
        case .blue: Color(red: 0.45, green: 0.72, blue: 1.0)
        case .pink: Color(red: 1.0, green: 0.55, blue: 0.68)
        case .violet: Color(red: 0.62, green: 0.56, blue: 0.98)
        }
    }

    /// Darker tone for rules, ticks and labels.
    var ink: Color {
        switch self {
        case .yellow: Color(red: 0.78, green: 0.55, blue: 0.0)
        case .green: Color(red: 0.2, green: 0.55, blue: 0.2)
        case .blue: Color(red: 0.12, green: 0.42, blue: 0.82)
        case .pink: Color(red: 0.82, green: 0.22, blue: 0.4)
        case .violet: Color(red: 0.4, green: 0.32, blue: 0.86)
        }
    }

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
