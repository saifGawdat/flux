import AppKit
import FluxCore
import UserNotifications

/// Posts "finished" and "failed" notifications. Downloads that finish close together are
/// summed up in one notification instead of a burst; playlists and galleries get one
/// notification when their last download stops. While Flux is in front they go straight
/// to Notification Center without a banner.
@MainActor
final class Notifier: NSObject {
    /// nil when running as a bare executable: notifications need an app bundle.
    private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier != nil ? .current() : nil
    private var pending: [DownloadMilestone] = []
    private var flushTask: Task<Void, Never>?
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Called with what the user chose in a notification.
    var onResponse: ((Response) -> Void)?

    enum Response {
        case show([UUID])
        case open(UUID)
        case reveal(UUID)
        case retry([UUID])
    }

    private enum Category {
        static let finished = "finished"
        static let finishedMany = "finished-many"
        static let failed = "failed"
    }

    private enum Action {
        static let open = "open"
        static let reveal = "reveal"
        static let retry = "retry"
    }

    /// How long to wait for more downloads to finish before notifying.
    static let gatherDelay: Duration = .seconds(1.5)

    var isAvailable: Bool { center != nil }

    override init() {
        super.init()
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.finished, actions: [
                UNNotificationAction(identifier: Action.open, title: "Open"),
                UNNotificationAction(identifier: Action.reveal, title: "Show in Finder"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.finishedMany, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.failed, actions: [
                UNNotificationAction(identifier: Action.retry, title: "Try Again"),
            ], intentIdentifiers: []),
        ])
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        guard let center else { return }
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks once; afterwards only System Settings can change the answer.
    func requestAuthorization() async {
        guard let center, authorization == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    func post(_ milestones: [DownloadMilestone], settings: FluxSettings) {
        let wanted = milestones.filter { milestone in
            switch milestone {
            case .finished: settings.notifyWhenFinished
            case .failed: settings.notifyOnFailure
            case .groupFinished(_, let finished, _): finished > 0 ? settings.notifyWhenFinished : settings.notifyOnFailure
            }
        }
        guard center != nil, !wanted.isEmpty else { return }
        pending += wanted
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: Self.gatherDelay)
            flushTask = nil
            await flush()
        }
    }

    /// A rule's "notify" action: sent even when finished-notifications are off, and
    /// instead of the ordinary one if that hasn't gone out yet.
    func post(_ record: DownloadRecord, rule: String) {
        pending.removeAll { if case .finished(let r) = $0 { r.id == record.id } else { false } }
        guard let center else { return }
        let content = Self.content("Download Finished", record.displayName, category: Category.finished, ids: [record.id])
        content.subtitle = "Rule “\(rule)”"
        if let note = record.automationNote { content.body += "\n" + note }
        Task {
            await requestAuthorization()
            guard authorization == .authorized || authorization == .provisional else { return }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func flush() async {
        let milestones = pending
        pending = []
        guard let center, !milestones.isEmpty else { return }
        await requestAuthorization()
        guard authorization == .authorized || authorization == .provisional else { return }
        for content in Self.contents(for: milestones) {
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    /// The notifications for a batch of milestones (separate for tests of the wording).
    static func contents(for milestones: [DownloadMilestone]) -> [UNMutableNotificationContent] {
        var result: [UNMutableNotificationContent] = []
        let finished = milestones.compactMap { if case .finished(let r) = $0 { r } else { nil } }
        let failed = milestones.compactMap { if case .failed(let r) = $0 { r } else { nil } }

        if finished.count == 1, let record = finished.first {
            result.append(content("Download Finished", record.displayName, category: Category.finished, ids: [record.id]))
        } else if finished.count > 1 {
            result.append(content("\(finished.count) Downloads Finished", names(finished),
                                  category: Category.finishedMany, ids: finished.map(\.id)))
        }
        for case .groupFinished(let group, let done, let failedCount) in milestones {
            let noun = group.kind == .images ? "image" : "download"
            var body = "\(done) \(noun)\(done == 1 ? "" : "s") finished"
            if failedCount > 0 { body += ", \(failedCount) failed" }
            let title = (group.kind == .images ? "Images Downloaded: " : "Playlist Downloaded: ") + group.title
            let item = content(title, body + ".", category: Category.finishedMany, ids: [])
            item.userInfo["group"] = group.id.uuidString
            result.append(item)
        }
        if failed.count == 1, let record = failed.first {
            result.append(content("Download Failed", "\(record.displayName): \(record.errorMessage ?? "The download stopped.")",
                                  category: Category.failed, ids: [record.id]))
        } else if failed.count > 1 {
            result.append(content("\(failed.count) Downloads Failed", names(failed), category: Category.failed, ids: failed.map(\.id)))
        }
        return result
    }

    private static func content(_ title: String, _ body: String, category: String, ids: [UUID]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.threadIdentifier = category
        content.userInfo = ["ids": ids.map(\.uuidString)]
        return content
    }

    /// "a.zip, b.pdf, c.dmg and 2 more".
    static func names(_ records: [DownloadRecord]) -> String {
        let shown = records.prefix(3).map(\.displayName).joined(separator: ", ")
        return records.count > 3 ? "\(shown) and \(records.count - 3) more" : shown
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let active = await MainActor.run { NSApp.isActive }
        return active ? [.list] : [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let ids = (info["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
        let group = (info["group"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        await MainActor.run {
            let choice: Response = switch action {
            case Action.open where ids.count == 1: .open(ids[0])
            case Action.reveal where ids.count == 1: .reveal(ids[0])
            case Action.retry: .retry(ids)
            default: .show(group.map { [$0] } ?? ids)
            }
            onResponse?(choice)
        }
    }
}
