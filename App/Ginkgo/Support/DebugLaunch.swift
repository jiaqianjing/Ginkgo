import SwiftData
import SwiftUI

/// Launch arguments for simulator checks without touch input:
/// `-seedSample YES` imports the sample chapter into an empty library, `-openFirst YES` opens it,
/// `-inMemoryStore YES` (see `Persistence`) keeps the run from touching the real library.
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
}
