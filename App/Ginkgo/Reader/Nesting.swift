import GinkgoAI
import GinkgoCore
import PDFKit
import SwiftUI

/// Marks inside marks: a word looked up inside a translated sentence. The relation comes from the passages' text
/// ranges, so nothing about it is stored. The inner mark takes taps and keeps its own colour; the cards point at
/// each other; the same words never get a second mark.
extension ReaderModel {
    // MARK: Relations

    /// Marks (highlights and rules, not ink) with a comparable passage.
    private var markPassages: [(record: AnnotationRecord, passage: PDFAnchor)] {
        annotations.compactMap { record in
            guard record.kind == .highlight, let passage = passages[record.id] else { return nil }
            return (record, passage)
        }
    }

    /// The mark on exactly these words, if any; of the given style when one is named.
    func mark(sameTextAs passage: PDFAnchor, style: MarkStyle? = nil) -> AnnotationRecord? {
        markPassages.first { $0.passage.sameText(as: passage) && (style == nil || $0.record.style == style) }?.record
    }

    /// The smallest mark around these words, of the given style when one is named.
    func enclosingMark(of passage: PDFAnchor, style: MarkStyle? = nil, withNote: Bool = false) -> AnnotationRecord? {
        markPassages
            .filter { $0.passage.encloses(passage) && (style == nil || $0.record.style == style) && (!withNote || $0.record.hasNote) }
            .min { ($0.passage.range?.length ?? .max) < ($1.passage.range?.length ?? .max) }?.record
    }

    /// The note on the passage around this one: the sentence a word card was looked up in.
    func parentNote(of id: UUID) -> AnnotationRecord? {
        passages[id].flatMap { enclosingMark(of: $0, withNote: true) }
    }

    /// Notes on passages inside this one, in reading order: the words looked up in a sentence.
    func childNotes(of id: UUID) -> [AnnotationRecord] {
        guard let outer = passages[id] else { return [] }
        return markPassages.filter { outer.encloses($0.passage) && $0.record.hasNote }.map(\.record)
    }

    /// Highlights lying inside this one, cut out of its fill so each keeps its own colour.
    func innerHighlights(of id: UUID) -> [UUID] {
        guard let outer = passages[id] else { return [] }
        return markPassages.filter { outer.encloses($0.passage) && $0.record.style == .highlight }.map(\.record.id)
    }

    /// Characters in a mark's passage; marks without a text range count as large, so text marks win taps.
    func passageLength(_ id: UUID) -> Int { passages[id]?.range?.length ?? .max }

    // MARK: Creating marks

    /// Plain marks of the same colour and style that the new one overlaps become one mark covering them all.
    /// Marks with notes never merge. Returns the merged mark, or nil when there was nothing to merge.
    func mergePlainMarks(with passage: PDFAnchor, color: HighlightColor, style: MarkStyle) -> AnnotationRecord? {
        let partners = markPassages.filter {
            !$0.record.hasNote && $0.record.color == color && $0.record.style == style && $0.passage.overlaps(passage)
        }
        guard !partners.isEmpty, var range = passage.range, let page = document.page(at: passage.pageIndex) else { return nil }
        for partner in partners { if let r = partner.passage.range { range = NSUnionRange(range, r) } }
        guard let merged = page.selection(for: range) else { return nil }
        partners.forEach { delete($0.record.id) }
        return highlight(merged, color: color, style: style, merge: false)
    }

    /// An AI task on selected text. The same words reuse their mark: a finished note takes the new question as a
    /// follow-up. Words inside a highlighted sentence get a rule, so sentence and word read apart.
    func run(_ task: AITask, on selection: PDFSelection, color: HighlightColor = .yellow) {
        if case .pdf(let passage)? = Self.anchor(for: selection, in: document) {
            if let existing = mark(sameTextAs: passage) {
                if selection === self.selection { clearSelection() }
                ask(task, about: existing)
                return
            }
            if enclosingMark(of: passage, style: .highlight) != nil {
                guard let record = highlight(selection, color: color, style: .underline, merge: false) else { return }
                run(task, on: record.id)
                return
            }
        }
        guard let record = highlight(selection, color: color, merge: false) else { return }
        run(task, on: record.id)
    }

    /// A task on a mark that may already carry a finished note.
    private func ask(_ task: AITask, about record: AnnotationRecord) {
        guard record.hasNote, record.replyState == .done else {
            run(task, on: record.id)
            return
        }
        switch task {
        case .translate where record.taskRaw == task.tag, .explain where record.taskRaw == task.tag:
            // Asked again for what the card already says: open it.
            withAnimation(.smooth(duration: 0.25)) {
                peeked.insert(record.id)
                collapsed.remove(record.id)
                focused = record.id
            }
        case .translate: followUp("把这段翻译一下。", on: record.id)
        case .explain: followUp("解释一下这段。", on: record.id)
        case .ask(let q), .handwritten(let q): followUp(q, on: record.id)
        }
    }
}
