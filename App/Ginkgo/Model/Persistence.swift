import Foundation
import SwiftData

enum Persistence {
    static let schema = Schema([Book.self, AnnotationRecord.self])

    /// On-disk store; `-inMemoryStore YES` gives a throwaway store for screenshots and tests.
    static func makeContainer() -> ModelContainer {
        let inMemory = UserDefaults.standard.bool(forKey: "inMemoryStore")
        // CloudKit stays off until the iCloud container is set up (phase 6); the models are already compatible.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not open the library store: \(error)")
        }
    }
}
