import GinkgoAI
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

    @Test func markdownCarriesFollowUpsAndKeyExpressions() {
        let r = AnnotationRecord(kind: .highlight, anchor: .pdf(PDFAnchor(pageIndex: 0, rects: [], quote: "It hedges.")))
        r.taskRaw = "translate"; r.replyText = "它在对冲。"
        r.study = StudyNote(keyItems: KeyItems(items: [KeyItem(text: "hedge", meaning: "对冲")]))
        r.thread = [FollowUp(question: "还有别的意思吗？", answer: "树篱。"), FollowUp(question: "没答完", error: "x")]
        let md = Exporter.markdown(title: "Book", annotations: [r])
        #expect(md.contains("- hedge：对冲"))
        #expect(md.contains("**追问**：还有别的意思吗？\n\n树篱。"))
        #expect(!md.contains("没答完"))
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

    @Test func removingANoteKeepsTheMarkAndUndoBringsItBack() throws {
        let book = try Library.importPDF(at: SamplePDF.writeFile(), into: context)
        defer { Library.delete(book, from: context) }
        let doc = try #require(PDFDocument(url: book.fileURL))
        let sel = try #require(doc.findString("living fossil", withOptions: []).first)
        let record = AnnotationRecord(kind: .highlight, anchor: try #require(ReaderModel.anchor(for: sel, in: doc)))
        record.book = book
        record.taskRaw = "translate"
        record.replyText = "活化石"
        record.replyState = .done
        record.thread = [FollowUp(question: "为什么？", answer: "因为……")]
        context.insert(record)
        try context.save()
        let model = ReaderModel(book: book, document: doc, context: context)
        let before = AnnotationSnapshot(record)

        model.removeNote(record.id)
        let kept = try #require(model.annotation(record.id))
        #expect(!kept.hasNote && kept.replyText == nil && kept.thread.isEmpty)
        #expect(kept.color == record.color)

        model.revert(to: before)
        let back = try #require(model.annotation(record.id))
        #expect(back.hasNote && back.replyText == "活化石" && back.thread.count == 1)
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

@Suite struct ScratchLayoutTests {
    @Test func wideWindowsPutTheSheetBesideThePage() {
        let layout = ReaderLayout(size: CGSize(width: 1210, height: 834), sidebar: true, scratch: 360)
        #expect(layout.scratchBeside)
        #expect(!layout.hasMarginColumn)
        #expect(layout.pageWidth == CGFloat(850))
    }

    @Test func narrowWindowsFloatTheSheetOverThePage() {
        let layout = ReaderLayout(size: CGSize(width: 834, height: 1210), scratch: 900)
        #expect(!layout.scratchBeside)
        #expect(layout.pageWidth == CGFloat(834))
        #expect(layout.scratchWidth == CGFloat(770))
    }

    @Test func aClosedSheetTakesNoRoom() {
        let layout = ReaderLayout(size: CGSize(width: 1210, height: 834), sidebar: true)
        #expect(!layout.scratchBeside && layout.hasMarginColumn)
    }
}

@MainActor @Suite struct NoteThreadTests {
    @Test func threadAndStudyRoundTripAndEmptyClearsStorage() {
        let r = AnnotationRecord(kind: .highlight, anchor: .pdf(PDFAnchor(pageIndex: 0, rects: [], quote: "q")))
        r.thread = [FollowUp(question: "a")]
        r.updateLastTurn { $0.answer = "b" }
        #expect(r.thread == [FollowUp(question: "a", answer: "b")])
        r.study.keyItemsError = "x"
        #expect(r.study.keyItemsError == "x")
        r.thread = []; r.study = StudyNote()
        #expect(r.threadData == nil && r.studyData == nil)
    }

    @Test func undoSnapshotSettlesAnUnansweredFollowUp() {
        let r = AnnotationRecord(kind: .highlight, anchor: .pdf(PDFAnchor(pageIndex: 0, rects: [], quote: "q")))
        r.thread = [FollowUp(question: "a", answer: "b"), FollowUp(question: "c")]
        let copy = AnnotationRecord(kind: .highlight, anchor: .pdf(PDFAnchor(pageIndex: 0, rects: [], quote: "q")))
        AnnotationSnapshot(r).apply(to: copy)
        #expect(copy.thread.count == 2)
        #expect(copy.thread[1].error != nil)
    }

    @Test func onlyForeignPassagesTeach() {
        #expect(AISettings.sameLanguage(.simplifiedChinese, "简体中文"))
        #expect(AISettings.sameLanguage(.traditionalChinese, "简体中文"))
        #expect(!AISettings.sameLanguage(.english, "简体中文"))
        #expect(AISettings.sameLanguage(.english, "English"))
    }
}

@MainActor struct FingerInputTests {
    @Test func explicitChoicesOverrideTheSystem() {
        #expect(FingerInput.draw.fingersDraw)
        #expect(!FingerInput.pencilOnly.fingersDraw)
        #expect(FingerInput.system.fingersDraw == !UIPencilInteraction.prefersPencilOnlyDrawing)
    }
}

@MainActor struct NestingTests {
    let context = ModelContext(try! ModelContainer(for: Persistence.schema,
                                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true)))

    func setUp() throws -> (Book, PDFDocument, ReaderModel) {
        let book = try Library.importPDF(at: SamplePDF.writeFile(), into: context)
        let doc = try #require(PDFDocument(url: book.fileURL))
        return (book, doc, ReaderModel(book: book, document: doc, context: context))
    }

    func find(_ text: String, in doc: PDFDocument) throws -> PDFSelection {
        try #require(doc.findString(text, withOptions: []).first)
    }

    @Test func theSameWordsKeepOneMark() throws {
        let (book, doc, model) = try setUp()
        defer { Library.delete(book, from: context) }
        let first = try #require(model.highlight(try find("living fossil", in: doc), color: .yellow))
        let again = try #require(model.highlight(try find("living fossil", in: doc), color: .green))
        #expect(again.id == first.id && again.color == .green)
        #expect(model.annotations.count == 1)
    }

    @Test func overlappingPlainMarksOfOneColourMerge() throws {
        let (book, doc, model) = try setUp()
        defer { Library.delete(book, from: context) }
        model.highlight(try find("often called a living", in: doc), color: .yellow)
        let merged = try #require(model.highlight(try find("a living fossil", in: doc), color: .yellow))
        #expect(model.annotations.count == 1)
        #expect(merged.anchor?.quote.contains("often called a living fossil") == true)
        // Another colour stays apart.
        model.highlight(try find("fossil. Its lineage", in: doc), color: .blue)
        #expect(model.annotations.count == 2)
    }

    @Test func marksWithNotesNeverMerge() throws {
        let (book, doc, model) = try setUp()
        defer { Library.delete(book, from: context) }
        let noted = try #require(model.highlight(try find("often called a living", in: doc), color: .yellow))
        noted.taskRaw = "explain"
        noted.replyText = "…"
        model.highlight(try find("a living fossil", in: doc), color: .yellow)
        #expect(model.annotations.count == 2)
    }

    @Test func aWordInsideASentenceIsRuledAndLinked() throws {
        let (book, doc, model) = try setUp()
        defer { Library.delete(book, from: context) }
        let sentence = try #require(model.highlight(try find("It hedges against catastrophe", in: doc), color: .yellow, merge: false))
        sentence.taskRaw = "translate"
        sentence.replyText = "它防范灾难"
        sentence.replyState = .done
        model.run(.translate, on: try find("hedges", in: doc))
        let word = try #require(model.annotations.first { $0.anchor?.quote == "hedges" })
        #expect(word.style == .underline)
        #expect(model.parentNote(of: word.id)?.id == sentence.id)
        #expect(model.childNotes(of: sentence.id).map(\.id) == [word.id])
        #expect(model.innerHighlights(of: sentence.id).isEmpty)  // a rule, not a highlight: nothing to cut out
        model.cancelTask(word.id)
    }

    @Test func askingAboutTheSameWordsAgainFollowsUp() throws {
        let (book, doc, model) = try setUp()
        defer { Library.delete(book, from: context) }
        let mark = try #require(model.highlight(try find("living fossil", in: doc), color: .yellow, merge: false))
        mark.taskRaw = "translate"
        mark.replyText = "活化石"
        mark.replyState = .done
        model.run(.explain, on: try find("living fossil", in: doc))
        #expect(model.annotations.count == 1)
        #expect(mark.thread.first?.question == "解释一下这段。")
        model.cancelTask(mark.id)
    }
}

struct MarkSegmentTests {
    @Test func anOuterLineSplitsAroundAnInnerHighlight() {
        let line = CGRect(x: 0, y: 0, width: 300, height: 20)
        let hole = CGRect(x: 100, y: 0, width: 50, height: 20)
        let pieces = MarkPainter.segments(of: [line], around: [hole])
        #expect(pieces.count == 2)
        #expect(pieces[0].minX == 0 && pieces[0].maxX < hole.minX)
        #expect(pieces[1].minX > hole.maxX && pieces[1].maxX == 300)
    }

    @Test func holesOnOtherLinesAndEdgeSliversAreIgnored() {
        let line = CGRect(x: 0, y: 0, width: 300, height: 20)
        #expect(MarkPainter.segments(of: [line], around: [CGRect(x: 100, y: 40, width: 50, height: 20)]) == [line])
        // A hole at the very start leaves no sliver before it.
        let pieces = MarkPainter.segments(of: [line], around: [CGRect(x: 0, y: 0, width: 60, height: 20)])
        #expect(pieces.count == 1 && pieces[0].minX > 60)
    }
}

@MainActor struct OneCardTests {
    @Test func openingANoteClosesTheOneBefore() throws {
        let context = ModelContext(try ModelContainer(for: Persistence.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let book = try Library.importPDF(at: SamplePDF.writeFile(), into: context)
        defer { Library.delete(book, from: context) }
        let doc = try #require(PDFDocument(url: book.fileURL))
        let model = ReaderModel(book: book, document: doc, context: context)
        let a = UUID(), b = UUID()
        model.peeked.insert(a)
        model.peeked.insert(b)
        #expect(model.peeked == [b])
    }
}
