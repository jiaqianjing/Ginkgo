import GinkgoAI
import GinkgoCore
import PDFKit
import PencilKit
import SwiftData
import SwiftUI

/// Launch arguments for simulator checks without touch input (DEBUG builds only):
/// - `-seedSample YES` imports the sample chapter into an empty library; `-openFirst YES` opens it.
/// - `-inMemoryStore YES` (see `Persistence`) keeps the run from touching the real library.
/// - `-demoAnnotate YES` adds a highlight, a translation, an explanation and a question to the open book
///   (the AI notes need a key; in the simulator pass one with `SIMCTL_CHILD_OPENAI_API_KEY`).
/// - `-orientation landscape` rotates (only in a build with UIRequiresFullScreen set).
/// - `-demoInk YES` turns on writing and draws an underline, a loop and a margin "?" on the first page.
/// - `-demoNotes YES` opens the notes panel after the demo notes have had time to arrive.
/// - `-demoMode review` starts in review mode; `-demoSelect "<text>"` selects text to show the selection menu.
enum DebugLaunch {
    static func seedIfRequested(context: ModelContext, open: (Book) -> Void) {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "seedSample") else { return }
        let existing = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let book = existing.first ?? (try? SamplePDF.writeFile()).flatMap { try? Library.importPDF(at: $0, into: context) }
        if defaults.bool(forKey: "openFirst"), let book { open(book) }
        #endif
    }

    static func annotateIfRequested(_ model: ReaderModel) async {
        #if DEBUG
        let d = UserDefaults.standard
        if d.string(forKey: "demoMode") == "review" { model.mode = .review }
        if let orientation = d.string(forKey: "orientation"),
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            // Needs a build with UIRequiresFullScreen; resizable windows refuse forced rotation.
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation == "landscape" ? .landscapeRight : .portrait)) { _ in }
        }
        try? await Task.sleep(for: .seconds(1))
        func find(_ text: String) -> PDFSelection? { model.document.findString(text, withOptions: []).first }
        if d.bool(forKey: "inMemoryStore"), let state = d.string(forKey: "visualFixture") {
            visualFixture(state, model: model)
        }
        if d.bool(forKey: "demoAnnotate"), model.annotations.isEmpty {
            if let s = find("rather than one thing brilliantly") { model.highlight(s, color: .green) }
            if let s = find("It hedges against catastrophe") { model.run(.translate, on: s) }
            if let s = find("hibakujumoku") { model.run(.explain, on: s, color: .violet) }
            if let s = find("guarded by the same tree") {
                model.run(.ask("银杏叶真的能防虫吗？"), on: s, color: .blue)
            }
            model.focused = nil
        }
        // `-demoPeek YES` opens every note's floating card; `-demoExpand YES` opens the first note in full.
        if d.bool(forKey: "demoPeek") { model.peeked = Set(model.notes.map(\.id)) }
        if d.bool(forKey: "demoExpand"), let first = model.notes.first { model.expand(first.id) }
        // `-demoTool <name>` picks a Pencil tool; `-demoPalette YES` opens the squeeze palette.
        if let raw = d.string(forKey: "demoTool") { model.tool = PenTool(rawValue: raw) }
        if d.bool(forKey: "demoPalette") { model.paletteAt = CGPoint(x: 420, y: 520) }
        if d.bool(forKey: "demoNotes") {
            try? await Task.sleep(for: .seconds(4))
            model.showNotes = true
        }
        if d.bool(forKey: "demoInk") {
            model.tool = .pen
            try? await Task.sleep(for: .seconds(0.6))
            model.pageInk.drawDemoStrokes(page: 0)
        }
        if let text = d.string(forKey: "demoSelect"), let s = find(text) {
            model.pdfView?.currentSelection = s
            model.selectionChanged(s)
        }
        if d.bool(forKey: "inMemoryStore") {
            if d.bool(forKey: "visualAsk"), let s = find("It hedges against catastrophe") { model.asking = .selection(s) }
            if d.bool(forKey: "visualHighlight"), let r = model.annotations.first { model.focused = r.id }
        }
        #endif
    }

    #if DEBUG
    /// Stable visual evidence only. Requires an in-memory store; never calls an AI provider.
    private static func visualFixture(_ state: String, model: ReaderModel) {
        let samples: [(String, HighlightColor, String, String)] = [
            ("It hedges against catastrophe", .yellow, "translate", "它用许多适度的优势分散风险，而不是把生存寄托在某一种过人的本领上。"),
            ("hibakujumoku", .violet, "explain", "「被爆树木」：原子弹爆炸后仍然存活、重新萌芽的树。这个词也承载着当地人对生命延续的珍视。"),
            ("guarded by the same tree", .blue, "ask", "这是一个把自然与阅读连在一起的比喻。银杏叶夹在书中，既是一枚书签，也寄托着保护书页的心愿。")
        ]
        for (index, sample) in samples.enumerated() {
            if state != "overview" && index > 0 { break }
            guard let selection = model.document.findString(sample.0, withOptions: []).first,
                  let record = model.highlight(selection, color: sample.1) else { continue }
            if state == "highlight" { continue }
            record.taskRaw = sample.2
            record.replyState = .done
            record.replyText = sample.3
            if index == 2 { record.question = "这里为什么提到书？" }
            switch state {
            case "pending": record.replyState = .pending; record.replyText = nil
            case "streaming": record.replyState = .streaming; record.replyText = "它用许多适度的优势分散风险，而不是把生存寄托在"
            case "failed": record.replyState = .failed; record.replyText = nil; record.replyError = AIError.http(status: 429, message: "Quota exceeded for metric: generate_content_free_tier_requests, limit: 20. Please retry in 14382.5s.").localizedDescription
            case "long": record.replyText = Array(repeating: sample.3, count: 6).joined(separator: "\n\n")
            case "handwriting":
                record.question = "为什么？"
                let points: [CGPoint] = [.init(x: 4, y: 8), .init(x: 12, y: 2), .init(x: 25, y: 4), .init(x: 30, y: 12), .init(x: 24, y: 20), .init(x: 17, y: 25), .init(x: 17, y: 34)]
                let controlPoints = points.enumerated().map { i, point in
                    PKStrokePoint(location: point, timeOffset: Double(i) * 0.05, size: CGSize(width: 2, height: 2), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
                }
                let stroke = PKStroke(ink: PKInk(.pen, color: .darkGray), path: PKStrokePath(controlPoints: controlPoints, creationDate: .now))
                record.inkData = PKDrawing(strokes: [stroke]).dataRepresentation()
                record.taskRaw = "ask"
            default: break
            }
        }
        model.reload()
        model.focused = nil
    }
    #endif
}
