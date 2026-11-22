import GinkgoCore
import PDFKit
import SwiftData
import SwiftUI
import Testing
import UIKit
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

@MainActor @Suite struct ExportTests {
    let context = ModelContext(try! ModelContainer(for: Persistence.schema,
                                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true)))

    @Test func markdownListsQuotesQuestionsAndAnswers() {
        let r = AnnotationRecord(kind: .highlight, anchor: .pdf(PDFAnchor(pageIndex: 2, rects: [], quote: "It hedges.")))
        r.taskRaw = "ask"; r.question = "为什么？"; r.replyText = "因为冗余。"
        let md = Exporter.markdown(title: "Book", annotations: [r])
        #expect(md.contains("> It hedges."))
        #expect(md.contains("第 3 页"))
        #expect(md.contains("**提问**：为什么？"))
        #expect(md.contains("因为冗余。"))
    }

    @Test func annotatedPDFCarriesHighlightsAndNotes() throws {
        let book = try Library.importPDF(at: SamplePDF.writeFile(), into: context)
        let doc = try #require(PDFDocument(url: book.fileURL))
        let sel = try #require(doc.findString("hibakujumoku", withOptions: []).first)
        let anchor = try #require(ReaderModel.anchor(for: sel, in: doc))
        let r = AnnotationRecord(kind: .highlight, anchor: anchor, color: .violet)
        r.taskRaw = "explain"; r.replyText = "被爆树木。"
        let url = try Exporter.writeAnnotatedPDF(for: book, annotations: [r])
        let out = try #require(PDFDocument(url: url))
        guard case .pdf(let a) = anchor else { return }
        let types = out.page(at: a.pageIndex)!.annotations.compactMap(\.type)
        #expect(types.contains("Highlight"))
        #expect(types.contains("Text"))
        Library.delete(book, from: context)
    }

    @Test func underlinesAndWavesExportAsStandardMarkup() throws {
        let book = try Library.importPDF(at: SamplePDF.writeFile(), into: context)
        let doc = try #require(PDFDocument(url: book.fileURL))
        func mark(_ text: String, _ style: MarkStyle) throws -> AnnotationRecord {
            let sel = try #require(doc.findString(text, withOptions: []).first)
            let r = AnnotationRecord(kind: .highlight, anchor: try #require(ReaderModel.anchor(for: sel, in: doc)), color: .blue)
            r.styleRaw = style.rawValue
            return r
        }
        let records = [try mark("hibakujumoku", .underline), try mark("living fossil", .squiggly)]
        let url = try Exporter.writeAnnotatedPDF(for: book, annotations: records)
        let out = try #require(PDFDocument(url: url))
        let types = (0..<out.pageCount).flatMap { out.page(at: $0)!.annotations.compactMap(\.type) }
        #expect(types.contains("Underline"))
        #expect(types.contains("Squiggly"))
        #expect(!types.contains("Highlight"))
        Library.delete(book, from: context)
    }

    /// SwiftUI resolves colours on its render thread; a main-actor colour provider crashed there on device.
    @Test func themeColoursResolveOffTheMainThread() async {
        let colors = [UIColor(Theme.accent), UIColor(Theme.glassTint), UIColor(Theme.Card.floatingShadow), UIColor(Theme.card)]
        let resolved = await Task.detached {
            colors.map { $0.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor.alpha }
        }.value
        #expect(resolved.count == 4)
    }

    @Test func clearingCountsAndRemovesEveryAnnotation() throws {
        let book = try Library.importPDF(at: SamplePDF.writeFile(), into: context)
        let doc = try #require(PDFDocument(url: book.fileURL))
        func record(_ text: String) throws -> AnnotationRecord {
            let sel = try #require(doc.findString(text, withOptions: []).first)
            let r = AnnotationRecord(kind: .highlight, anchor: try #require(ReaderModel.anchor(for: sel, in: doc)))
            r.book = book
            context.insert(r)
            return r
        }
        _ = try record("living fossil")
        _ = try record("hibakujumoku").taskRaw = "explain"
        let ink = AnnotationRecord(kind: .ink, anchor: .pdf(PDFAnchor(pageIndex: 0, rects: [], quote: "")))
        ink.inkData = Data([1]); ink.book = book
        context.insert(ink)
        try context.save()

        let count = Library.AnnotationCount(book.annotations ?? [])
        #expect(count.highlights == 1 && count.notes == 1 && count.inkPages == 1)
        #expect(count.summary == "1 条高亮和划线、1 条 AI 批注、1 页笔迹")

        Library.clearAnnotations(of: book, in: context)
        #expect(Library.AnnotationCount(book.annotations ?? []).isEmpty)
        #expect(FileManager.default.fileExists(atPath: book.fileURL.path))
        Library.delete(book, from: context)
    }
}
