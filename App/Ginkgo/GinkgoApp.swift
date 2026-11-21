import SwiftData
import SwiftUI

@main
struct GinkgoApp: App {
    let container: ModelContainer

    init() {
        container = Persistence.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(container)
    }
}
