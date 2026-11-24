import Foundation
import GinkgoAI
import GinkgoCore
import PDFKit
import PencilKit
import UIKit

/// Turns a book's annotations into files that leave the app: Markdown notes, and a PDF with standard annotations
/// (highlights, ink, and text notes carrying the AI answers) that any PDF reader can show.
enum Exporter {
    /// Notes in reading order: quote, page, what was asked and the answer.
    static func markdown(title: String, annotations: [AnnotationRecord]) -> String {
        var out = "# \(title)\n\n"
        let marks = annotations.filter { $0.kind != .ink }
        if marks.isEmpty { return out + "_还没有批注。_\n" }
        for record in marks {
            guard case .pdf(let a)? = record.anchor else { continue }
            let quote = a.quote.replacingOccurrences(of: "\n", with: " ")
            out += "> \(quote)\n>\n> — 第 \(a.pageIndex + 1) 页\n\n"
            if record.hasNote {
                var label = "**\(record.taskLabel)**"
                if let q = record.question, !q.isEmpty { label += "：\(q)" }
                out += label + "\n\n"
                if let reply = record.replyText, !reply.isEmpty { out += reply + "\n\n" }
                out += studyMarkdown(record.study)
                for turn in record.thread where !turn.answer.isEmpty {
                    out += "**追问**：\(turn.question)\n\n\(turn.answer)\n\n"
                }
            }
            out += "---\n\n"
        }
        return out
    }

    /// Key expressions and the grammar walk-through of a learner's translation. The word card is already the reply.
    static func studyMarkdown(_ study: StudyNote) -> String {
        var out = ""
        if let items = study.keyItems?.items, !items.isEmpty {
            out += "**重点表达**\n\n"
            for item in items {
                out += "- \(item.text)" + (item.meaning.map { "：\($0)" } ?? "")
                if let note = item.note, !note.isEmpty { out += "（\(note)）" }
                out += "\n"
            }
            out += "\n"
        }
        if let analysis = study.analysis { out += "**语法分析**\n\n\(analysis.summary)\n\n" }
        return out
    }

    static func writeMarkdown(for book: Book, annotations: [AnnotationRecord]) throws -> URL {
        let url = exportURL(book.title, ext: "md")
        try markdown(title: book.title, annotations: annotations).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A copy of the book's PDF with every annotation written as a standard PDF annotation.
    static func writeAnnotatedPDF(for book: Book, annotations: [AnnotationRecord]) throws -> URL {
        guard let document = PDFDocument(url: book.fileURL) else { throw CocoaError(.fileReadCorruptFile) }
        for record in annotations {
            guard case .pdf(let a)? = record.anchor, let page = document.page(at: a.pageIndex) else { continue }
            let color = UIColor(record.color.fill)
            switch record.kind {
            case .ink:
                if let data = record.inkData, let drawing = try? PKDrawing(data: data) {
                    addInk(drawing, to: page)
                }
            case .highlight, .question:
                for rect in a.rects {
                    let h = PDFAnnotation(bounds: rect, forType: subtype(for: record.style), withProperties: nil)
                    h.color = record.style == .highlight ? color.withAlphaComponent(0.5) : UIColor(Theme.markLine(record.color))
                    page.addAnnotation(h)
                }
                if record.hasNote, let last = a.rects.last {
                    let note = PDFAnnotation(bounds: CGRect(x: last.maxX + 2, y: last.maxY - 18, width: 18, height: 18),
                                             forType: .text, withProperties: nil)
                    note.color = color
                    var text = record.taskLabel
                    if let q = record.question, !q.isEmpty { text += "：\(q)" }
                    if let reply = record.replyText, !reply.isEmpty { text += "\n\n\(reply)" }
                    if let items = record.study.keyItems?.items, !items.isEmpty {
                        text += "\n\n重点表达：\n" + items.map { "- \($0.text)" + ($0.meaning.map { "：\($0)" } ?? "") }.joined(separator: "\n")
                    }
                    if let analysis = record.study.analysis { text += "\n\n语法分析：\n\(analysis.summary)" }
                    for turn in record.thread where !turn.answer.isEmpty { text += "\n\n追问：\(turn.question)\n\(turn.answer)" }
                    note.contents = text
                    page.addAnnotation(note)
                }
            }
        }
        let url = exportURL(book.title + "（批注）", ext: "pdf")
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Highlights, underlines and waves map to the standard Highlight, Underline and Squiggly markup annotations.
    /// PDFKit has no constant for Squiggly, so its name is built from Underline's to keep the same spelling.
    static func subtype(for style: MarkStyle) -> PDFAnnotationSubtype {
        switch style {
        case .highlight: .highlight
        case .underline: .underline
        case .squiggly: PDFAnnotationSubtype(rawValue: PDFAnnotationSubtype.underline.rawValue.replacingOccurrences(of: "Underline", with: "Squiggly"))
        }
    }

    /// Page ink is stored in page points with y growing down (the overlay canvas's space).
    private static func addInk(_ drawing: PKDrawing, to page: PDFPage) {
        let box = page.bounds(for: .cropBox)
        let bounds = drawing.bounds
        guard !bounds.isEmpty else { return }
        let rect = CGRect(x: box.minX + bounds.minX - 4, y: box.maxY - bounds.maxY - 4,
                          width: bounds.width + 8, height: bounds.height + 8)
        let ink = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
        ink.color = UIColor(red: 0.18, green: 0.2, blue: 0.26, alpha: 1)
        let border = PDFBorder()
        border.lineWidth = 1.6
        ink.border = border
        for stroke in drawing.strokes {
            let path = UIBezierPath()
            for (i, point) in stroke.path.enumerated() {
                let p = point.location.applying(stroke.transform)
                // Ink paths are relative to the annotation's bounds origin.
                let q = CGPoint(x: box.minX + p.x - rect.minX, y: box.maxY - p.y - rect.minY)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            ink.add(path)
        }
        page.addAnnotation(ink)
    }

    private static func exportURL(_ name: String, ext: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.temporaryDirectory.appending(path: "Export", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(safe).\(ext)")
        try? FileManager.default.removeItem(at: url)
        return url
    }
}
