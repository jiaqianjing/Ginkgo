import GinkgoAI
import GinkgoCore
import PDFKit
import SwiftData
import SwiftUI

/// Launch arguments for simulator checks without touch input (DEBUG builds only):
/// - `-seedSample YES` imports the sample chapter into an empty library; `-openFirst YES` opens it.
/// - `-inMemoryStore YES` (see `Persistence`) keeps the run from touching the real library.
/// - `-demoAnnotate YES` adds a highlight, a translation, an explanation and a question to the open book
///   (the AI notes need a key; in the simulator pass one with `SIMCTL_CHILD_OPENAI_API_KEY`).
/// - `-orientation landscape` rotates (only in a build with UIRequiresFullScreen set).
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
        if d.string(forKey: "orientation") == "landscape",
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            // Needs a build with UIRequiresFullScreen; resizable windows refuse forced rotation.
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
        try? await Task.sleep(for: .seconds(1))
        func find(_ text: String) -> PDFSelection? { model.document.findString(text, withOptions: []).first }
        if d.bool(forKey: "demoAnnotate"), model.annotations.isEmpty {
            if let s = find("rather than one thing brilliantly") { model.highlight(s, color: .green) }
            if let s = find("It hedges against catastrophe") { model.run(.translate, on: s) }
            if let s = find("hibakujumoku") { model.run(.explain, on: s, color: .violet) }
            if let s = find("guarded by the same tree") {
                model.run(.ask("银杏叶真的能防虫吗？"), on: s, color: .blue)
            }
            model.focused = nil
        }
        if let text = d.string(forKey: "demoSelect"), let s = find(text) {
            model.pdfView?.currentSelection = s
            model.selectionChanged(s)
        }
        #endif
    }
}
