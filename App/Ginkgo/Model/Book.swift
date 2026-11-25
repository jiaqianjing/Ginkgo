import Foundation
import SwiftData

/// A PDF in the library. The file itself lives in iCloud Drive or the local library folder (`BookFiles`); this
/// record holds what the UI needs without opening it and syncs through CloudKit, which is why every property has
/// a default and relationships are optional.
@Model
final class Book {
    var id: UUID = UUID()
    var title: String = ""
    /// File name inside the book folder (`BookFiles`).
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

    /// Local until iCloud takes it (see `BookFiles`); may not be downloaded yet on a new device.
    var fileURL: URL { BookFiles.url(for: fileName) }

    /// Most recently read first; books never opened sort by when they were added.
    var recency: Date { lastOpenedAt ?? addedAt }

    var progress: Double {
        pageCount > 1 ? Double(lastPageIndex) / Double(pageCount - 1) : 0
    }
}
