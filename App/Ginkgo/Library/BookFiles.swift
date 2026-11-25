import Foundation
import Observation
import OSLog
import Synchronization

/// Where book files live. With iCloud on, in the app's iCloud Drive container (not shown in the Files app, so
/// nobody renames a file out from under its record), which brings them to every device; without it, in
/// Application Support. A file imported before iCloud was available moves over once it is.
///
/// The records (books, marks, notes, ink) sync separately through SwiftData's CloudKit mirroring.
@Observable
final class BookFiles {
    static let shared = BookFiles()
    nonisolated static let containerID = "iCloud.com.kenjia.ginkgo"
    nonisolated private static let log = Logger(subsystem: "com.kenjia.ginkgo", category: "files")

    /// The `Books` folder in the iCloud container, once found. Nil without iCloud.
    private(set) var cloudDirectory: URL? {
        didSet { Self.cloud.withLock { $0 = cloudDirectory } }
    }
    /// The same, for model code that isn't on the main actor (`Book.fileURL`).
    nonisolated private static let cloud = Mutex<URL?>(nil)
    /// Whether the container lookup has finished (so a missing file is really missing, not just early).
    private(set) var resolved = false
    /// Bumped whenever iCloud reports file changes, so views re-check download state.
    private(set) var revision = 0

    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Where a book's file is now: still in the local folder if it hasn't moved yet, else in iCloud.
    func url(for fileName: String) -> URL { Self.url(for: fileName) }

    nonisolated static func url(for fileName: String) -> URL {
        let local = Library.directory.appending(path: fileName)
        guard let cloud = cloud.withLock({ $0 })?.appending(path: fileName) else { return local }
        return FileManager.default.fileExists(atPath: local.path) ? local : cloud
    }

    /// Whether the file is on this device and can be opened.
    func isReady(_ fileName: String) -> Bool {
        _ = revision
        return Self.isReady(url(for: fileName))
    }

    nonisolated static func isReady(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
            return FileManager.default.fileExists(atPath: url.path)
        }
        return values.ubiquitousItemDownloadingStatus == .current
    }

    /// Asks iCloud for a file that isn't on this device yet.
    func download(_ fileName: String) {
        guard cloudDirectory != nil else { return }
        let url = url(for: fileName)
        Task.detached { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
    }

    // MARK: Launch

    /// Finds the container (slow the first time, so off the main thread), moves local files into it and keeps
    /// every book downloaded.
    func start() async {
        let cloud: URL? = await Task.detached {
            guard let root = FileManager.default.url(forUbiquityContainerIdentifier: BookFiles.containerID) else { return nil }
            let dir = root.appending(path: "Books", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }.value
        cloudDirectory = cloud
        resolved = true
        guard let cloud else {
            Self.log.info("iCloud unavailable; books stay on this device")
            return
        }
        await Task.detached { Self.moveLocalFiles(to: cloud) }.value
        revision += 1
        watch()
    }

    /// A newly imported file joins the others in iCloud.
    func adopt(_ fileName: String) {
        guard let cloud = cloudDirectory else { return }
        Task.detached {
            Self.move(Library.directory.appending(path: fileName), to: cloud.appending(path: fileName))
            await MainActor.run { BookFiles.shared.revision += 1 }
        }
    }

    /// Removes a book's file wherever it is; in iCloud the deletion reaches the other devices too.
    func remove(_ fileName: String) {
        var urls = [Library.directory.appending(path: fileName)]
        if let cloud = cloudDirectory { urls.append(cloud.appending(path: fileName)) }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: nil) { url in
                try? FileManager().removeItem(at: url)
            }
        }
    }

    private nonisolated static func moveLocalFiles(to cloud: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Library.directory.path)) ?? []
        for name in names where name.hasSuffix(".pdf") {
            move(Library.directory.appending(path: name), to: cloud.appending(path: name))
        }
    }

    private nonisolated static func move(_ local: URL, to cloud: URL) {
        let fm = FileManager()
        guard fm.fileExists(atPath: local.path) else { return }
        if fm.fileExists(atPath: cloud.path) {
            try? fm.removeItem(at: local)  // already there (file names are UUIDs)
            return
        }
        do { try fm.setUbiquitous(true, itemAt: local, destinationURL: cloud) }
        catch { log.error("Could not move \(local.lastPathComponent, privacy: .public) to iCloud: \(error, privacy: .public)") }
    }

    /// Watches the container: anything not yet on this device is asked for, and views hear about changes.
    private func watch() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.pdf'", NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { _ in
                MainActor.assumeIsolated { BookFiles.shared.queryChanged() }
            })
        }
        self.query = query
        query.start()
    }

    private func queryChanged() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
                    != NSMetadataUbiquitousItemDownloadingStatusCurrent else { continue }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        revision += 1
    }
}
