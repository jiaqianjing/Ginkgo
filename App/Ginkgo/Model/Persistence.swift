import Foundation
import OSLog
import SwiftData

enum Persistence {
    static let schema = Schema([Book.self, AnnotationRecord.self])
    private static let log = Logger(subsystem: "com.kenjia.ginkgo", category: "store")

    /// On-disk store mirrored to the reader's private CloudKit database, so every device signed in to the same
    /// Apple account sees the same library. Without an iCloud account it simply stays local.
    /// `-inMemoryStore YES` gives a throwaway local store for screenshots and tests.
    static func makeContainer() -> ModelContainer {
        let inMemory = UserDefaults.standard.bool(forKey: "inMemoryStore")
        if !inMemory {
            backUpOnce()
            do {
                let config = ModelConfiguration(schema: schema, cloudKitDatabase: .private(BookFiles.containerID))
                return try ModelContainer(for: schema, configurations: config)
            } catch {
                // Better a local library than none: reading must never depend on iCloud.
                log.error("CloudKit store failed, opening locally: \(error, privacy: .public)")
            }
        }
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not open the library store: \(error)")
        }
    }

    /// A throwaway local store. Spelled out because a bare configuration defaults to CloudKit once the app has
    /// iCloud entitlements, and tests must never reach for the network.
    static func memoryContainer() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                                                           cloudKitDatabase: .none))
    }

    /// One copy of the store from before sync was first switched on, in case the first upload goes wrong.
    private static func backUpOnce() {
        let fm = FileManager.default
        let support = URL.applicationSupportDirectory
        let backup = support.appending(path: "Backups/before-icloud", directoryHint: .isDirectory)
        guard !fm.fileExists(atPath: backup.path) else { return }
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            let source = support.appending(path: name)
            guard fm.fileExists(atPath: source.path) else { continue }
            try? fm.copyItem(at: source, to: backup.appending(path: name))
        }
    }
}
