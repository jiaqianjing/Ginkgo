import GinkgoCore
import PDFKit
import SwiftData
import Testing
@testable import Ginkgo

@MainActor @Suite struct LibraryTests {
    let context = ModelContext(try! ModelContainer(for: Persistence.schema,
                                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true)))

    @Test func importCopiesTheFileAndReadsItsPages() throws {
        let book = try Library.importPDF(at: SamplePDF.writeFile(), into: context)
        #expect(book.pageCount > 1)
        #expect(book.title == "A Living Fossil")
        #expect(book.coverData != nil)
        #expect(FileManager.default.fileExists(atPath: book.fileURL.path))
        Library.delete(book, from: context)
        #expect(!FileManager.default.fileExists(atPath: book.fileURL.path))
    }

    @Test func rejectsFilesThatAreNotPDFs() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "notes.pdf")
        try Data("not a pdf".utf8).write(to: url)
        #expect(throws: Library.ImportError.self) { try Library.importPDF(at: url, into: context) }
    }

    @Test func annotationAnchorSurvivesStorage() throws {
        let anchor = Anchor.pdf(PDFAnchor(pageIndex: 0, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)], quote: "q"))
        let record = AnnotationRecord(kind: .highlight, anchor: anchor, color: .green)
        context.insert(record)
        #expect(record.anchor == anchor)
        #expect(record.color == .green)
    }
}
