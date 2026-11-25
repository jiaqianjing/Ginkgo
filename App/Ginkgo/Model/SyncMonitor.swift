import CoreData
import Foundation
import Observation

/// How iCloud sync is doing, for the line in Settings. SwiftData mirrors through an `NSPersistentCloudKitContainer`
/// underneath, which reports each setup, import and export as an event.
@Observable
final class SyncMonitor {
    static let shared = SyncMonitor()

    enum State: Equatable {
        /// No iCloud account, or iCloud is off for Ginkgo.
        case unavailable
        case waiting
        case syncing
        case synced(Date)
        case failed(String)
    }

    private(set) var state: State = .waiting
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        refreshAccount()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                            object: nil, queue: .main) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let finished = event.endDate, ok = event.succeeded, setup = event.type == .setup
            let message = event.error?.localizedDescription
            MainActor.assumeIsolated {
                SyncMonitor.shared.update(finished: finished, succeeded: ok, setup: setup, error: message)
            }
        })
        observers.append(center.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SyncMonitor.shared.refreshAccount() }
        })
    }

    private func refreshAccount() {
        if FileManager.default.ubiquityIdentityToken == nil { state = .unavailable }
        else if state == .unavailable { state = .waiting }
    }

    func update(finished: Date?, succeeded: Bool, setup: Bool, error: String?) {
        guard state != .unavailable else { return }
        guard let finished else { state = .syncing; return }
        if !succeeded { state = .failed(error ?? "未知错误") }
        else if !setup { state = .synced(finished) }
        else if state == .syncing { state = .waiting }
    }

    var summary: String {
        switch state {
        case .unavailable: "未开启"
        case .waiting: "已开启"
        case .syncing: "正在同步…"
        case .synced(let date): "已同步 · \(date.formatted(date: .omitted, time: .shortened))"
        case .failed: "同步出错"
        }
    }
}
