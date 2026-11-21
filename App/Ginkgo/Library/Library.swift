import Foundation
import PDFKit
import SwiftData
import UIKit

/// Imports PDFs into the app's own storage and removes them again.
enum Library {
    /// Where imported PDFs live. Phase 6 moves this into the iCloud Drive container.
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
            case .unreadable(let name): "「\(name)」不是可以打开的 PDF。"
            case .locked(let name): "「\(name)」有密码保护，暂时不能导入。"
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
        return book
    }

    static func delete(_ book: Book, from context: ModelContext) {
        try? FileManager.default.removeItem(at: book.fileURL)
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
