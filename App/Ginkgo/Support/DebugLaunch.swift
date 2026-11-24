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
        if d.bool(forKey: "demoPalette") {
            let x = d.double(forKey: "demoPaletteX"), y = d.double(forKey: "demoPaletteY")
            model.paletteAt = CGPoint(x: x > 0 ? x : 420, y: y > 0 ? y : 520)
        }
        if d.bool(forKey: "demoNotes") {
            try? await Task.sleep(for: .seconds(4))
            model.showNotes = true
        }
        if d.bool(forKey: "demoInk") {
            model.tool = .pen
            try? await Task.sleep(for: .seconds(0.6))
            model.pageInk.drawDemoStrokes(page: 0)
        }
        // `-demoScratch YES` opens the scratch sheet.
        if d.bool(forKey: "demoScratch") { model.showScratch = true }
        // `-demoClear YES` clears every annotation once the demo has settled.
        if d.bool(forKey: "demoClear") {
            try? await Task.sleep(for: .seconds(2))
            model.clearAll()
        }
        // `-demoUndo N` undoes N steps after the demo has settled; `-demoRedo N` then redoes N.
        let undos = d.integer(forKey: "demoUndo"), redos = d.integer(forKey: "demoRedo")
        if undos > 0 || redos > 0 {
            try? await Task.sleep(for: .seconds(2.5))
            for _ in 0..<undos {
                model.undo(); try? await Task.sleep(for: .seconds(0.3))
            }
            for _ in 0..<redos { model.redo(); try? await Task.sleep(for: .seconds(0.3)) }
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
            if state != "overview", state != "study", index > 0 { break }
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
            case "study":
                // A learner's notes: a word card, a sentence with key expressions, analysis and a follow-up.
                if index == 0 {
                    record.study = StudyNote(keyItems: KeyItems(items: [
                        KeyItem(text: "hedge against", kind: "collocation", phonetic: "/hedʒ əˈɡenst/", meaning: "防范、对冲（风险）", note: "常见于金融语境，这里是比喻"),
                        KeyItem(text: "catastrophe", kind: "word", phonetic: "/kəˈtæstrəfi/", meaning: "大灾难"),
                        KeyItem(text: "rather than", kind: "pattern", meaning: "而不是")
                    ], analysisWorthy: true, analysisHint: "比较结构 + 省略"))
                    record.thread = [FollowUp(question: "hedge 还有别的意思吗？", answer: "名词是「树篱」，动词也可以指说话留余地，比如 hedge one's answer。这里取的是「对冲风险」的比喻义。")]
                }
                if index == 1 {
                    record.taskRaw = "translate"
                    var word = WordCard()
                    word.term = "hibakujumoku"; word.phonetic = "/hibakɯ̥dʑɯmokɯ/"
                    word.contextMeaning = "被爆树木：原子弹爆炸后幸存的树"
                    word.senses = [WordCard.Sense(pos: "n.", meaning: "（日语借词）广岛、长崎原爆后存活的树木")]
                    word.example = WordCard.Example(source: "the hibakujumoku of Hiroshima", target: "广岛的被爆树木")
                    word.note = "日语「被爆樹木」的罗马字，英文里常保留原词"
                    record.study = StudyNote(word: word)
                    record.replyText = word.summary
                }
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
        if state == "study" {
            // Inside the first sentence: a word card on a rule, and a plain green highlight cut out of the yellow.
            if let word = model.document.findString("catastrophe", withOptions: []).first,
               let record = model.highlight(word, color: .yellow, style: .underline, merge: false) {
                var card = WordCard()
                card.term = "catastrophe"; card.phonetic = "/kəˈtæstrəfi/"
                card.contextMeaning = "（足以毁掉物种的）大灾难"
                card.senses = [WordCard.Sense(pos: "n.", meaning: "灾难，大祸")]
                record.taskRaw = "translate"
                record.study = StudyNote(word: card)
                record.replyText = card.summary
                record.replyState = .done
            }
            if let word = model.document.findString("hedges", withOptions: []).first {
                model.highlight(word, color: .green, merge: false)
            }
        }
        model.reload()
        model.focused = nil
    }
    #endif
}
