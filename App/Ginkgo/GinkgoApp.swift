import SwiftData
import SwiftUI

@main
struct GinkgoApp: App {
    let container: ModelContainer

    init() {
        _ = SyncMonitor.shared  // listen before the store starts its first sync
        container = Persistence.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .tint(Theme.accent)
                .foregroundStyle(Theme.ink)
                .task { await BookFiles.shared.start() }
        }
        .modelContainer(container)
    }
}
