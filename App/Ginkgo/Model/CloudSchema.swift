import CoreData
import Foundation
import OSLog
import SwiftData

/// Builds the whole CloudKit schema in the Development environment, before it is deployed to Production.
///
/// Mirroring only creates the fields it has uploaded a value for, so a young library leaves some out (follow-ups,
/// study cards, scratch sheets). Production never grows fields on its own, so every one must exist in Development
/// first. Run a debug build once with `-initCloudKitSchema YES` after changing the models, then deploy in the
/// CloudKit Console. Uses a scratch store of its own; the real library is not touched. It waits on the network, so it
/// runs off the main thread after launch (in `init` the launch watchdog would kill the app first).
nonisolated enum CloudSchema {
    private static let log = Logger(subsystem: "com.kenjia.ginkgo", category: "store")
    /// Written to Application Support so a run on a device can be checked afterwards.
    static let resultFile = URL.applicationSupportDirectory.appending(path: "cloudkit-schema.txt")

    static func initializeIfRequested() async {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "initCloudKitSchema") else { return }
        await Task.detached { run() }.value
        #endif
    }

    #if DEBUG
    private static func run() {
        let result: String
        do {
            try initialize()
            result = "ok \(Date.now.formatted(.iso8601))"
            log.info("CloudKit schema initialized")
        } catch {
            result = "failed \(Date.now.formatted(.iso8601)): \(error)"
            log.error("CloudKit schema initialization failed: \(error, privacy: .public)")
        }
        try? result.write(to: resultFile, atomically: true, encoding: .utf8)
    }

    private static func initialize() throws {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: [Book.self, AnnotationRecord.self]) else {
            throw CocoaError(.coderInvalidValue)
        }
        let url = URL.temporaryDirectory.appending(path: "cloudkit-schema.store")
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: BookFiles.containerID)
        description.shouldAddStoreAsynchronously = false
        let container = NSPersistentCloudKitContainer(name: "Ginkgo", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        defer {
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores { try? coordinator.remove(store) }
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        try container.initializeCloudKitSchema()
    }
    #endif
}
