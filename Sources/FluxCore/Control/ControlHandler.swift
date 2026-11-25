import Foundation

/// Carries out command-line requests with the app's own `DownloadManager`, so the
/// `flux` tool and the window always agree.
public struct ControlHandler: Sendable {
    public let manager: DownloadManager

    public init(manager: DownloadManager) {
        self.manager = manager
    }

    public func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            return try await run(request)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func run(_ request: ControlRequest) async throws -> ControlResponse {
        let targets = request.targets ?? []
        switch request.command {
        case .ping:
            return ControlResponse(message: "Flux is running.")

        case .add:
            let entries = request.entries ?? []
            guard !entries.isEmpty else { return .failure("No links to add.") }
            let queue = try await queueID(named: request.queue)
            let requests = entries.map { entry in
                DownloadManager.NewDownload(
                    url: entry.url, directory: entry.directory, fileName: entry.fileName,
                    startImmediately: request.paused != true, referer: entry.referer,
                    mirrors: entry.mirrors, checksum: entry.checksum, queue: queue)
            }
            let ids = try await manager.add(requests)
            let items = await ids.asyncCompactMap { await manager.item($0) }
            return ControlResponse(
                message: "Added \(Self.count(ids.count, "download"))\(request.queue.map { " to “\($0)”" } ?? "").",
                downloads: await summaries(items), ids: ids.map { $0.uuidString.lowercased() })

        case .list:
            let items = await manager.allItems.filter { request.includeHistory == true || !$0.record.isArchived }
            return ControlResponse(downloads: await summaries(items))

        case .status:
            let ids = try await resolve(targets)
            let items = await ids.asyncCompactMap { await manager.item($0) }
            return ControlResponse(downloads: await summaries(items))

        case .pause:
            let ids = try await eligible(try await resolve(targets), \.canPause)
            try await manager.pause(ids)
            return ControlResponse(message: Self.changed("Paused", ids.count, nothing: "Nothing to pause."), ids: Self.strings(ids))

        case .resume:
            let ids = try await eligible(try await resolve(targets), \.canResume)
            try await manager.resume(ids)
            return ControlResponse(message: Self.changed("Resumed", ids.count, nothing: "Nothing to resume."), ids: Self.strings(ids))

        case .cancel:
            let ids = try await eligible(try await resolve(targets), \.canCancel)
            try await manager.cancel(ids)
            return ControlResponse(message: Self.changed("Cancelled", ids.count, nothing: "Nothing to cancel."), ids: Self.strings(ids))

        case .remove:
            let ids = try await resolve(targets)
            try await manager.remove(ids, trashFiles: request.trash == true)
            let what = request.trash == true ? "and moved the files to the Trash" : "(files kept)"
            return ControlResponse(message: "Removed \(Self.count(ids.count, "download")) \(what).", ids: Self.strings(ids))

        case .limit:
            var settings = await manager.settings
            if let limit = request.speedLimit {
                settings.speedLimitEnabled = limit > 0
                if limit > 0 { settings.speedLimit = max(limit, FluxSettings.minimumSpeedLimit) }
                try await manager.updateSettings(settings)
                settings = await manager.settings
            }
            let message = settings.effectiveSpeedLimit.map { "Speed limit: \(Self.speed($0)) for all downloads together." }
                ?? "No speed limit."
            return ControlResponse(message: message, speedLimit: settings.effectiveSpeedLimit)

        case .queues:
            return ControlResponse(queues: await queueSummaries())

        case .startQueue, .stopQueue:
            guard let name = targets.first, let id = try await queueID(named: name) else {
                return .failure("Name the queue, e.g. flux queue start Night.")
            }
            if request.command == .startQueue { await manager.startQueue(id) } else { await manager.stopQueue(id) }
            let queueName = await manager.queue(id)?.name ?? name
            return ControlResponse(
                message: "\(request.command == .startQueue ? "Started" : "Stopped") “\(queueName)”.",
                queues: await queueSummaries())

        case .export:
            let ids = targets.isEmpty ? nil : try await resolve(targets)
            let records = await manager.allItems
                .filter { item in ids.map { $0.contains(item.id) } ?? (request.includeHistory == true || !item.record.isArchived) }
                .map(\.record)
            let data = LinkList.export(records, format: request.format ?? .text)
            return ControlResponse(message: "Exported \(Self.count(records.count, "download")).",
                                   text: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: Helpers

    /// IDs from full IDs, unique prefixes (as `flux list` shows them) or "all".
    private func resolve(_ targets: [String]) async throws -> [UUID] {
        guard !targets.isEmpty else { throw HandlerError("Name at least one download (an ID from flux list), or all.") }
        let items = await manager.allItems.filter { !$0.record.isArchived }
        if targets.contains(where: { $0.lowercased() == "all" }) { return items.map(\.id) }
        let everything = await manager.allItems
        var result: [UUID] = []
        for target in targets {
            let key = target.lowercased()
            let matches = everything.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
            switch matches.count {
            case 0: throw HandlerError("No download with ID \(target). See flux list.")
            case 1: result.append(matches[0].id)
            default: throw HandlerError("“\(target)” matches \(matches.count) downloads. Use more of the ID.")
            }
        }
        return result
    }

    /// The downloads a command applies to: pausing a finished download does nothing.
    private func eligible(_ ids: [UUID], _ allowed: KeyPath<DownloadStatus, Bool>) async throws -> [UUID] {
        await ids.asyncCompactMap { id in
            guard let status = await manager.item(id)?.record.status, status[keyPath: allowed] else { return nil }
            return id
        }
    }

    static func changed(_ verb: String, _ count: Int, nothing: String) -> String {
        count == 0 ? nothing : "\(verb) \(Self.count(count, "download"))."
    }

    private func queueID(named name: String?) async throws -> UUID? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if ["main", "main queue"].contains(name.lowercased()) { return nil }
        let queues = await manager.settings.queues
        if let queue = queues.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return queue.id }
        let names = queues.map(\.name)
        throw HandlerError("No queue named “\(name)”." + (names.isEmpty ? " Create queues in Flux." : " Queues: \(names.joined(separator: ", "))."))
    }

    private func summaries(_ items: [DownloadManager.Item]) async -> [DownloadSummary] {
        let queues = await manager.settings.queues
        return items.map { item in
            DownloadSummary(item, queueName: item.record.queueID.flatMap { id in queues.first { $0.id == id }?.name })
        }
    }

    private func queueSummaries() async -> [QueueSummary] {
        let settings = await manager.settings
        let items = await manager.allItems.filter { !$0.record.isArchived }
        func counts(_ id: UUID?) -> (waiting: Int, active: Int) {
            let members = items.filter { $0.record.queueID == id }
            return (members.filter { $0.record.status == .queued }.count, members.filter { $0.record.status.isActive }.count)
        }
        let main = counts(nil)
        var result = [QueueSummary(id: "main", name: "Main", isMain: true, isRunning: true, schedule: nil,
                                   waiting: main.waiting, active: main.active)]
        for queue in settings.queues {
            let c = counts(queue.id)
            result.append(QueueSummary(id: queue.id.uuidString.lowercased(), name: queue.name, isMain: false,
                                       isRunning: queue.isRunning, schedule: queue.schedule?.summary,
                                       waiting: c.waiting, active: c.active))
        }
        return result
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func strings(_ ids: [UUID]) -> [String] { ids.map { $0.uuidString.lowercased() } }

    static func speed(_ bytesPerSecond: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .decimal) + "/s"
    }

    struct HandlerError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

extension Sequence where Element: Sendable {
    func asyncCompactMap<T>(_ transform: (Element) async -> T?) async -> [T] {
        var result: [T] = []
        for element in self { if let value = await transform(element) { result.append(value) } }
        return result
    }
}
