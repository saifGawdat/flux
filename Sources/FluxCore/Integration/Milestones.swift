import Foundation

/// Something worth telling the user about while Flux is in the background.
public enum DownloadMilestone: Sendable, Equatable {
    case finished(DownloadRecord)
    case failed(DownloadRecord)
    /// Every download of a playlist or gallery stopped (finished, failed or cancelled).
    case groupFinished(DownloadGroup, finished: Int, failed: Int)
}

/// Turns the stream of download updates into milestones: a download that *becomes*
/// finished or failed while Flux watches. What was already finished at launch, repeated
/// updates of the same state, and cancellations by the user say nothing. Downloads of a
/// playlist or gallery are reported once, as a group, when the last of them stops.
public struct MilestoneTracker: Sendable {
    private var status: [UUID: DownloadStatus] = [:]
    private var group: [UUID: UUID] = [:]

    public init() {}

    /// Learns the current state without reporting anything (launch, reload).
    public mutating func baseline(_ records: some Sequence<DownloadRecord>) {
        status = [:]
        group = [:]
        for record in records { remember(record) }
    }

    public mutating func forget(_ ids: some Sequence<UUID>) {
        for id in ids {
            status[id] = nil
            group[id] = nil
        }
    }

    /// Records one update; returns what it completes. `all` resolves group members.
    public mutating func observe(_ record: DownloadRecord, all: (UUID) -> DownloadRecord?) -> [DownloadMilestone] {
        let previous = status[record.id]
        remember(record)
        guard let previous, previous != record.status, !record.isArchived else { return [] }
        guard record.status == .completed || record.status == .failed || record.status == .cancelled else { return [] }

        if let groupInfo = record.group {
            let members = group.filter { $0.value == groupInfo.id }.keys
                .compactMap { $0 == record.id ? record : all($0) }
                .filter { !$0.isArchived }
            guard members.allSatisfy({ Self.isStopped($0.status) }) else { return [] }
            let finished = members.filter { $0.status == .completed }.count
            let failed = members.filter { $0.status == .failed }.count
            guard finished + failed > 0 else { return [] }
            return [.groupFinished(groupInfo, finished: finished, failed: failed)]
        }
        switch record.status {
        case .completed: return [.finished(record)]
        case .failed: return [.failed(record)]
        default: return []
        }
    }

    private mutating func remember(_ record: DownloadRecord) {
        status[record.id] = record.status
        group[record.id] = record.group?.id
    }

    private static func isStopped(_ status: DownloadStatus) -> Bool {
        status == .completed || status == .failed || status == .cancelled
    }
}

/// How far along the running downloads are, together. For the Dock and the menu bar.
public enum OverallProgress {
    /// Bytes received / bytes expected over running downloads whose size is known;
    /// nil when nothing is running or no running download has a known size.
    public static func fraction(of records: some Sequence<DownloadRecord>) -> Double? {
        var received: Int64 = 0
        var total: Int64 = 0
        for record in records where record.status.isActive && !record.isArchived {
            guard let size = record.totalBytes, size > 0 else { continue }
            total += size
            received += min(record.receivedBytes, size)
        }
        guard total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }
}
