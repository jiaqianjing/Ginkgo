import Foundation
import PDFKit
import SwiftData
import UIKit

/// Imports PDFs into the app's own storage and removes them again.
enum Library {
    /// Where imported PDFs land first, and stay when there is no iCloud (see `BookFiles`).
    nonisolated static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    enum ImportError: LocalizedError {
        case unreadable(String)
        case locked(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): String(localized: "「\(name)」不是可以打开的 PDF。")
            case .locked(let name): String(localized: "「\(name)」有密码保护，暂时不能导入。")
            }
        }
    }

    /// Copies the file into the library and creates its record. `url` may be security-scoped (from Files).
    @discardableResult
    static func importPDF(at url: URL, into context: ModelContext) throws -> Book {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = url.deletingPathExtension().lastPathComponent
        guard let document = PDFDocument(url: url) else { throw ImportError.unreadable(name) }
        guard !document.isLocked else { throw ImportError.locked(name) }

        let fileName = UUID().uuidString + ".pdf"
        try FileManager.default.copyItem(at: url, to: directory.appending(path: fileName))

        let book = Book(title: title(of: document) ?? name, fileName: fileName,
                        pageCount: document.pageCount, coverData: cover(of: document))
        context.insert(book)
        BookFiles.shared.adopt(fileName)
        return book
    }

    /// What a book's annotations add up to, for the "clear all" confirmation.
    struct AnnotationCount: Equatable {
        var highlights = 0, notes = 0, inkPages = 0
        var isEmpty: Bool { highlights + notes + inkPages == 0 }

        init(_ records: [AnnotationRecord]) {
            for r in records {
                if r.kind == .ink { if r.inkData != nil { inkPages += 1 } }
                else if r.hasNote { notes += 1 }
                else { highlights += 1 }
            }
        }

        /// e.g. "12 条高亮和划线、3 条 AI 批注、2 页笔迹".
        var summary: String {
            var parts: [String] = []
            if highlights > 0 { parts.append(String(localized: "\(highlights) 条高亮和划线")) }
            if notes > 0 { parts.append(String(localized: "\(notes) 条 AI 批注")) }
            if inkPages > 0 { parts.append(String(localized: "\(inkPages) 页笔迹")) }
            return parts.joined(separator: String(localized: "、"))
        }
    }

    /// Back to the book as imported: every annotation goes. The PDF file itself was never changed.
    static func clearAnnotations(of book: Book, in context: ModelContext) {
        for record in book.annotations ?? [] { context.delete(record) }
        try? context.save()
    }

    static func delete(_ book: Book, from context: ModelContext) {
        BookFiles.shared.remove(book.fileName)
        context.delete(book)
    }

    /// The document's own title, when it has a meaningful one (many PDFs carry "Microsoft Word - x.docx").
    private static func title(of document: PDFDocument) -> String? {
        guard let t = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().hasPrefix("microsoft") || trimmed.lowercased() == "untitled" {
            return nil
        }
        return trimmed
    }

    /// First page as a JPEG, sized for the library grid on a Retina screen.
    private static func cover(of document: PDFDocument) -> Data? {
        guard let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let width: CGFloat = 480
        let size = CGSize(width: width, height: width * bounds.height / max(bounds.width, 1))
        return page.thumbnail(of: size, for: .cropBox).jpegData(compressionQuality: 0.82)
    }
}
