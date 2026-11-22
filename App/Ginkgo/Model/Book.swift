import Foundation
import SwiftData

/// A PDF in the library. The file itself lives in `Library.directory`; this record holds what the UI needs
/// without opening it. Every property has a default and relationships are optional so CloudKit sync can be
/// switched on later without a migration.
@Model
final class Book {
    var id: UUID = UUID()
    var title: String = ""
    /// File name inside `Library.directory`.
    var fileName: String = ""
    var addedAt: Date = Date.now
    var lastOpenedAt: Date?
    var lastPageIndex: Int = 0
    var pageCount: Int = 0
    @Attribute(.externalStorage) var coverData: Data?
    /// The book's scratch sheet (a PencilKit drawing), kept apart from the pages.
    @Attribute(.externalStorage) var scratchData: Data?

    @Relationship(deleteRule: .cascade, inverse: \AnnotationRecord.book)
    var annotations: [AnnotationRecord]? = []

    init(title: String, fileName: String, pageCount: Int, coverData: Data?) {
        self.title = title
        self.fileName = fileName
        self.pageCount = pageCount
        self.coverData = coverData
    }

    var fileURL: URL { Library.directory.appending(path: fileName) }

    /// Most recently read first; books never opened sort by when they were added.
    var recency: Date { lastOpenedAt ?? addedAt }

    var progress: Double {
        pageCount > 1 ? Double(lastPageIndex) / Double(pageCount - 1) : 0
    }
}
