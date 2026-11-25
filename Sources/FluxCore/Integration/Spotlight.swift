import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// What Spotlight knows about one finished download.
public struct SpotlightEntry: Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var file: URL
    public var source: URL
    public var site: String?
    public var collection: String?
    public var finishedAt: Date?
    public var contentType: UTType

    /// Finished downloads whose file (or extracted folder) still exists; nil otherwise.
    public init?(_ record: DownloadRecord, fileExists: (URL) -> Bool) {
        guard record.status == .completed else { return nil }
        guard let file = [record.finalPath, record.extractedPath].compactMap({ $0 }).first(where: fileExists) else { return nil }
        id = record.id
        title = record.displayName
        self.file = file
        source = record.url
        site = (record.referer ?? record.url).host()
        collection = record.group?.title
        finishedAt = record.completedAt
        contentType = file.hasDirectoryPath && file == record.extractedPath
            ? .folder
            : UTType(filenameExtension: file.pathExtension) ?? .data
    }

    public var searchableItem: CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: contentType)
        attributes.title = title
        attributes.displayName = title
        attributes.contentURL = file
        attributes.contentDescription = ["Downloaded with Flux", site.map { "from \($0)" }, collection.map { "· \($0)" }]
            .compactMap { $0 }.joined(separator: " ")
        attributes.keywords = ["download", "flux", site, collection, file.lastPathComponent].compactMap { $0 }
        attributes.url = source
        attributes.contentCreationDate = finishedAt
        attributes.addedDate = finishedAt
        let item = CSSearchableItem(uniqueIdentifier: id.uuidString,
                                    domainIdentifier: SpotlightSync.domain, attributeSet: attributes)
        // Items expire after a month unless told otherwise.
        item.expirationDate = .distantFuture
        return item
    }
}

/// Keeps track of which downloads Spotlight lists, so updates only send what changed.
public struct SpotlightSync: Sendable {
    public static let domain = "app.flux.downloads"
    /// A full rebuild lists at most this many downloads, newest first.
    public static let limit = 10_000

    public enum Change: Sendable, Equatable {
        case upsert(SpotlightEntry)
        case delete(UUID)
    }

    private var indexed: [UUID: SpotlightEntry] = [:]

    public init() {}

    public var count: Int { indexed.count }

    /// Everything that should be listed, for a rebuild from scratch.
    public mutating func rebuild(_ records: some Sequence<DownloadRecord>, fileExists: (URL) -> Bool) -> [SpotlightEntry] {
        let entries = records
            .filter { $0.status == .completed }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
            .prefix(Self.limit)
            .compactMap { SpotlightEntry($0, fileExists: fileExists) }
        indexed = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return entries
    }

    /// What one update changes, if anything.
    public mutating func update(_ record: DownloadRecord, fileExists: (URL) -> Bool) -> Change? {
        // Cheap exit for the many progress updates of running downloads.
        if record.status != .completed, indexed[record.id] == nil { return nil }
        guard let entry = SpotlightEntry(record, fileExists: fileExists) else {
            return indexed.removeValue(forKey: record.id) == nil ? nil : .delete(record.id)
        }
        guard indexed[record.id] != entry else { return nil }
        indexed[record.id] = entry
        return .upsert(entry)
    }

    /// Downloads removed from Flux.
    public mutating func remove(_ ids: some Sequence<UUID>) -> [UUID] {
        ids.filter { indexed.removeValue(forKey: $0) != nil }
    }

    public mutating func clear() { indexed = [:] }
}

/// Sends changes to the system's Spotlight index. Needs a real app bundle.
// CSSearchableIndex is thread-safe (documented), it just isn't marked Sendable.
public final class SpotlightIndexer: @unchecked Sendable {
    private let index: CSSearchableIndex?

    public init() {
        index = Bundle.main.bundleIdentifier != nil && CSSearchableIndex.isIndexingAvailable() ? .default() : nil
    }

    public var isAvailable: Bool { index != nil }

    /// Replaces everything Flux listed with `entries`.
    public func replaceAll(with entries: [SpotlightEntry]) async {
        guard let index else { return }
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightSync.domain])
            for batch in stride(from: 0, to: entries.count, by: 500) {
                try await index.indexSearchableItems(entries[batch..<min(batch + 500, entries.count)].map(\.searchableItem))
            }
        } catch {
            Log.manager.error("Spotlight: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func apply(_ changes: [SpotlightSync.Change]) async {
        guard let index, !changes.isEmpty else { return }
        var upserts: [CSSearchableItem] = []
        var deletions: [String] = []
        for change in changes {
            switch change {
            case .upsert(let entry): upserts.append(entry.searchableItem)
            case .delete(let id): deletions.append(id.uuidString)
            }
        }
        do {
            if !deletions.isEmpty { try await index.deleteSearchableItems(withIdentifiers: deletions) }
            if !upserts.isEmpty { try await index.indexSearchableItems(upserts) }
        } catch {
            Log.manager.error("Spotlight: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func removeAll() async {
        guard let index else { return }
        try? await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightSync.domain])
    }

    /// The download a Spotlight result stands for (from the activity it opens Flux with).
    public static func downloadID(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        return UUID(uuidString: identifier)
    }
}
