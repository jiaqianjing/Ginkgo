import Observation
import PDFKit
import PencilKit
import SwiftUI

enum AnnotationStyle: String, CaseIterable, Identifiable {
    case sidenote, foldedMark, handwritten
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sidenote: "A 页边旁注"
        case .foldedMark: "B 一线一卡"
        case .handwritten: "C 手写回应"
        }
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case reading, review
    var id: String { rawValue }
    var label: String { self == .reading ? "阅读" : "回顾" }
}

enum NoteKind {
    case translate, explain, ask

    var label: String {
        switch self {
        case .translate: "翻译"
        case .explain: "解释"
        case .ask: "提问"
        }
    }

    /// Accent used for the margin mark, card rule and text.
    var accent: Color {
        switch self {
        case .translate: Palette.gold
        case .explain: Palette.graphite
        case .ask: Palette.sage
        }
    }

    /// Fill used for the marker on the page.
    var highlight: Color {
        switch self {
        case .translate: Color(red: 0.97, green: 0.78, blue: 0.31).opacity(0.5)
        case .explain: Palette.graphite.opacity(0.16)
        case .ask: Color(red: 0.49, green: 0.67, blue: 0.46).opacity(0.32)
        }
    }

    var tint: Color {
        switch self {
        case .translate: Color(red: 0.984, green: 0.945, blue: 0.847)
        case .explain: Color(red: 0.925, green: 0.937, blue: 0.961)
        case .ask: Color(red: 0.914, green: 0.941, blue: 0.902)
        }
    }
}

enum Palette {
    static let gold = Color(red: 0.788, green: 0.541, blue: 0.118)
    static let graphite = Color(red: 0.294, green: 0.357, blue: 0.478)
    static let sage = Color(red: 0.369, green: 0.510, blue: 0.349)
    static let ink = Color(red: 0.137, green: 0.125, blue: 0.106)
    static let inkMuted = Color(red: 0.482, green: 0.455, blue: 0.408)
    static let paper = Color(red: 0.988, green: 0.980, blue: 0.961)
    static let desk = Color(red: 0.902, green: 0.886, blue: 0.859)
}

/// How a note marks its passage on the page.
enum MarkShape { case marker, circle, underline }

/// One text line of an anchor, in PDF page space. Kept behind this small type so other anchor kinds
/// (reflowable text ranges) can be added later without touching the views.
struct PageLine {
    var pageIndex: Int
    var bounds: CGRect
}

struct Note: Identifiable {
    let id = UUID()
    var kind: NoteKind
    var mark: MarkShape
    var quote: String
    var question: String?
    var ink: PKDrawing?
    var body: String
    var lines: [PageLine]
    var pending = false
}

/// Anchor lines of a note converted into the reader's coordinate space for the current scroll and zoom.
struct NoteGeometry {
    var lines: [CGRect]
    var first: CGRect { lines.first ?? .zero }
    var union: CGRect { lines.dropFirst().reduce(first) { $0.union($1) } }
}

@Observable
final class ReaderModel {
    var style: AnnotationStyle = .sidenote
    var mode: ViewMode = .review
    var document: PDFDocument
    var documentName = "The Patient Tree（示例）"
    var notes: [Note] = []

    /// Updated on every scroll / zoom by the PDF view coordinator.
    var geometry: [UUID: NoteGeometry] = [:]
    /// Visible frame of each page in reader space, used for B's in-page margin marks.
    var pageFrames: [Int: CGRect] = [:]
    var cardHeights: [UUID: CGFloat] = [:]

    var expanded: Set<UUID> = []
    var collapsed: Set<UUID> = []
    var peeked: UUID?
    var active: UUID?
    var penOn = false

    /// The current text selection, for the "翻译 / 解释 / 提问" menu.
    var selection: PDFSelection?
    var selectionRect: CGRect?
    var askingAbout: PDFSelection?

    @ObservationIgnored weak var pdfView: PDFView?

    init() {
        document = SamplePDF.makeDocument()
        // Launch arguments for screenshots, e.g. `-style foldedMark -mode reading`.
        let d = UserDefaults.standard
        if let s = d.string(forKey: "style").flatMap(AnnotationStyle.init(rawValue:)) { style = s }
        if let m = d.string(forKey: "mode").flatMap(ViewMode.init(rawValue:)) { mode = m }
        seedSampleNotes()
    }

    func open(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let doc = PDFDocument(data: data) else { return }
        notes = []
        geometry = [:]
        expanded = []
        document = doc
        documentName = url.deletingPathExtension().lastPathComponent
    }

    func isOpen(_ note: Note) -> Bool {
        if peeked == note.id { return true }
        switch (style, mode) {
        // B: everything open in review; in reading mode only what was tapped.
        case (.foldedMark, .review): return !collapsed.contains(note.id)
        case (.foldedMark, .reading): return expanded.contains(note.id)
        case (_, .review): return true
        case (_, .reading): return false
        }
    }

    /// Opens or folds a B-style card; which set holds the override depends on the mode.
    func toggleFold(_ id: UUID) {
        if mode == .review {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        } else {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    // MARK: - Sample notes

    private func seedSampleNotes() {
        add(.translate, mark: .marker,
            quote: "It hedges against catastrophe by doing many modest things well, rather than one thing brilliantly.",
            body: "它靠把许多平凡的事都做好来抵御灾难，而不是把一件事做到极致。")
        add(.explain, mark: .circle, quote: "hibakujumoku",
            body: "被爆树木（日语「被爆樹木」）：指 1945 年原子弹爆炸后存活下来的树。广岛登记在册的有一百多棵，其中包括几棵银杏，至今仍被当地人照料。")
        add(.ask, mark: .underline,
            quote: "A reader's library was, in this sense, guarded by the same tree that had outlasted the dinosaurs.",
            question: "银杏叶真的能防虫吗？",
            body: "有一定道理。银杏叶含有银杏酸等成分，对一些昆虫有驱避作用，但效果有限。古人夹叶子更多是经验做法，后来也成了一种读书人的风雅习惯。")
        add(.explain, mark: .marker, quote: "dichotomous venation",
            body: "二叉脉序：叶脉一分为二、再一分为二，直通叶缘，不连成网。这是很古老的叶脉形式，蕨类里常见。")
    }

    private func add(_ kind: NoteKind, mark: MarkShape, quote: String, question: String? = nil, body: String) {
        guard let sel = find(quote) else { return }
        notes.append(Note(kind: kind, mark: mark, quote: quote, question: question, body: body, lines: lines(of: sel)))
    }

    /// Text search that ignores whitespace, since PDF text extraction may put line breaks between words.
    private func find(_ quote: String) -> PDFSelection? {
        if let s = document.findString(quote, withOptions: []).first { return s }
        let target = Array(quote.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard !target.isEmpty else { return nil }
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i), let text = page.string else { continue }
            // Non-whitespace scalars with their UTF-16 offsets in the page text.
            var chars: [(Unicode.Scalar, Int)] = []
            var offset = 0
            for u in text.unicodeScalars {
                if !CharacterSet.whitespacesAndNewlines.contains(u) { chars.append((u == "\u{2019}" ? "'" : u, offset)) }
                offset += u.utf16.count
            }
            guard chars.count >= target.count else { continue }
            for s in 0...(chars.count - target.count) where chars[s].0 == target[0] {
                var ok = true
                for k in 1..<target.count where chars[s + k].0 != target[k] { ok = false; break }
                if ok {
                    let lo = chars[s].1, hi = chars[s + target.count - 1].1 + 1
                    return page.selection(for: NSRange(location: lo, length: hi - lo))
                }
            }
        }
        return nil
    }

    func lines(of selection: PDFSelection) -> [PageLine] {
        selection.selectionsByLine().compactMap { line in
            guard let page = line.pages.first else { return nil }
            let b = line.bounds(for: page)
            guard b.width > 1 else { return nil }
            return PageLine(pageIndex: document.index(for: page), bounds: b)
        }
    }

    // MARK: - New notes

    func create(_ kind: NoteKind, from selection: PDFSelection, question: String? = nil) {
        let quote = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let mark: MarkShape = kind == .explain && !quote.contains(" ") ? .circle : (kind == .ask ? .underline : .marker)
        let note = Note(kind: kind, mark: mark, quote: quote, question: question, body: "",
                        lines: lines(of: selection), pending: true)
        notes.append(note)
        pdfView?.clearSelection()
        self.selection = nil
        if style == .foldedMark { expanded.insert(note.id) }
        if mode == .reading { peeked = note.id }
        active = note.id
        answer(note.id)
    }

    func createInk(_ drawing: PKDrawing, recognized: String, at line: PDFSelection) {
        let note = Note(kind: .ask, mark: .underline, quote: line.string ?? "", question: recognized.isEmpty ? nil : recognized,
                        ink: drawing, body: "", lines: lines(of: line), pending: true)
        notes.append(note)
        if style == .foldedMark { expanded.insert(note.id) }
        active = note.id
        answer(note.id)
    }

    /// Placeholder for the model call: the prototype isn't wired to SwipeSayKit yet.
    private func answer(_ id: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
            let n = notes[i]
            let excerpt = n.quote.count > 40 ? String(n.quote.prefix(40)) + "…" : n.quote
            let body: String
            switch n.kind {
            case .translate: body = "（示意）这里会显示「\(excerpt)」的译文。原型还没有接模型。"
            case .explain: body = "（示意）这里会解释「\(excerpt)」的意思，并结合上下文说明它在这句话里的作用。"
            case .ask:
                let q = n.question.map { "「\($0)」" } ?? "这个问题"
                body = "（示意）关于\(q)，回答会写在这里，篇幅控制在两三句，像老师写在书边的话。"
            }
            withAnimation(.smooth) {
                notes[i].body = body
                notes[i].pending = false
            }
        }
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        geometry[id] = nil
        expanded.remove(id)
    }
}
