import Foundation
import Testing
@testable import FluxCore

private func record(
    _ name: String, _ status: DownloadStatus, group: DownloadGroup? = nil,
    received: Int64 = 0, total: Int64? = nil, file: URL? = nil
) -> DownloadRecord {
    var r = DownloadRecord(url: URL(string: "https://example.com/\(name)")!,
                           directory: URL(fileURLWithPath: "/tmp"), fileName: name)
    r.status = status
    r.group = group
    r.totalBytes = total
    if received > 0 || total != nil { r.segments = [Segment(start: 0, end: (total ?? received) - 1, received: received)] }
    r.finalPath = file
    if status == .completed { r.completedAt = Date() }
    return r
}

struct MilestoneTests {
    @Test func reportsOnlyChangesWhileWatching() {
        var tracker = MilestoneTracker()
        let done = record("old.zip", .completed)
        var running = record("new.zip", .downloading)
        tracker.baseline([done, running])
        // Already finished at launch, and repeated updates: nothing.
        #expect(tracker.observe(done) { _ in nil }.isEmpty)
        #expect(tracker.observe(running) { _ in nil }.isEmpty)

        running.status = .completed
        #expect(tracker.observe(running) { _ in nil } == [.finished(running)])
        #expect(tracker.observe(running) { _ in nil }.isEmpty)
    }

    @Test func failuresYesCancellationsNo() {
        var tracker = MilestoneTracker()
        var a = record("a.zip", .downloading)
        var b = record("b.zip", .downloading)
        tracker.baseline([a, b])
        a.status = .failed
        b.status = .cancelled
        #expect(tracker.observe(a) { _ in nil } == [.failed(a)])
        #expect(tracker.observe(b) { _ in nil }.isEmpty)
    }

    @Test func newDownloadsAreWatchedFromTheirFirstUpdate() {
        var tracker = MilestoneTracker()
        tracker.baseline([])
        var a = record("a.zip", .queued)
        #expect(tracker.observe(a) { _ in nil }.isEmpty)
        a.status = .completed
        #expect(tracker.observe(a) { _ in nil } == [.finished(a)])
    }

    @Test func aPlaylistIsReportedOnceWhenItsLastDownloadStops() {
        let group = DownloadGroup(title: "Talks", kind: .playlist)
        var items = [record("1.mp4", .downloading, group: group), record("2.mp4", .downloading, group: group),
                     record("3.mp4", .queued, group: group)]
        var tracker = MilestoneTracker()
        tracker.baseline(items)
        func update(_ index: Int, _ status: DownloadStatus) -> [DownloadMilestone] {
            items[index].status = status
            let all = items
            return tracker.observe(items[index]) { id in all.first { $0.id == id } }
        }
        #expect(update(0, .completed).isEmpty)
        #expect(update(1, .failed).isEmpty)
        #expect(update(2, .downloading).isEmpty)
        #expect(update(2, .completed) == [.groupFinished(group, finished: 2, failed: 1)])
    }

    @Test func archivedAndForgottenDownloadsSayNothing() {
        var tracker = MilestoneTracker()
        var a = record("a.zip", .downloading)
        tracker.baseline([a])
        tracker.forget([a.id])
        a.status = .completed
        #expect(tracker.observe(a) { _ in nil }.isEmpty)
    }
}

struct OverallProgressTests {
    @Test func combinesRunningDownloadsWithKnownSizes() {
        let records = [
            record("a", .downloading, received: 50, total: 100),
            record("b", .downloading, received: 150, total: 300),
            record("c", .downloading, received: 999), // size unknown: left out
            record("d", .paused, received: 0, total: 1000), // not running
            record("e", .completed, received: 10, total: 10),
        ]
        #expect(OverallProgress.fraction(of: records) == 0.5)
    }

    @Test func nothingRunningMeansNoBar() {
        #expect(OverallProgress.fraction(of: [record("a", .paused, received: 5, total: 10)]) == nil)
        #expect(OverallProgress.fraction(of: [record("a", .downloading, received: 5)]) == nil)
        #expect(OverallProgress.fraction(of: [DownloadRecord]()) == nil)
    }
}

struct SpotlightSyncTests {
    let existing: Set<String> = ["/tmp/a.zip", "/tmp/b.pdf", "/tmp/moved/b.pdf"]
    func exists(_ url: URL) -> Bool { existing.contains(url.path) }

    @Test func listsFinishedDownloadsWhoseFilesExist() throws {
        let group = DownloadGroup(title: "Course", kind: .playlist)
        var a = record("a.zip", .completed, file: URL(fileURLWithPath: "/tmp/a.zip"))
        a.group = group
        a.referer = URL(string: "https://pages.example.org/list")
        let gone = record("gone.zip", .completed, file: URL(fileURLWithPath: "/tmp/gone.zip"))
        let running = record("c.iso", .downloading)
        var sync = SpotlightSync()
        let entries = sync.rebuild([a, gone, running], fileExists: exists)
        #expect(entries.map(\.id) == [a.id])
        let entry = try #require(entries.first)
        #expect(entry.title == "a.zip")
        #expect(entry.site == "pages.example.org")
        #expect(entry.collection == "Course")
        #expect(entry.contentType == .zip)
        let item = entry.searchableItem
        #expect(item.uniqueIdentifier == a.id.uuidString)
        #expect(item.domainIdentifier == SpotlightSync.domain)
        #expect(item.expirationDate == .distantFuture)
        #expect(item.attributeSet.contentURL?.path == "/tmp/a.zip")
    }

    @Test func sendsOnlyWhatChanged() {
        var sync = SpotlightSync()
        var b = record("b.pdf", .downloading)
        _ = sync.rebuild([b], fileExists: exists)
        #expect(sync.update(b, fileExists: exists) == nil) // progress: nothing

        b.status = .completed
        b.finalPath = URL(fileURLWithPath: "/tmp/b.pdf")
        guard case .upsert(let first)? = sync.update(b, fileExists: exists) else { Issue.record("expected upsert"); return }
        #expect(first.file.path == "/tmp/b.pdf")
        #expect(sync.update(b, fileExists: exists) == nil) // same again: nothing

        b.finalPath = URL(fileURLWithPath: "/tmp/moved/b.pdf") // filed by a rule
        guard case .upsert(let moved)? = sync.update(b, fileExists: exists) else { Issue.record("expected upsert"); return }
        #expect(moved.file.path == "/tmp/moved/b.pdf")

        b.finalPath = nil // trashed as a duplicate
        #expect(sync.update(b, fileExists: exists) == .delete(b.id))
        #expect(sync.update(b, fileExists: exists) == nil)
        #expect(sync.count == 0)
    }

    @Test func removedDownloadsAreDeletedOnce() {
        var sync = SpotlightSync()
        let a = record("a.zip", .completed, file: URL(fileURLWithPath: "/tmp/a.zip"))
        _ = sync.rebuild([a], fileExists: exists)
        #expect(sync.remove([a.id, UUID()]) == [a.id])
        #expect(sync.remove([a.id]).isEmpty)
    }

    @Test func spotlightResultsLeadBackToTheDownload() {
        let id = UUID()
        let activity = NSUserActivity(activityType: "com.apple.corespotlightitem")
        activity.userInfo = ["kCSSearchableItemActivityIdentifier": id.uuidString]
        #expect(SpotlightIndexer.downloadID(from: activity) == id)
        #expect(SpotlightIndexer.downloadID(from: NSUserActivity(activityType: "other")) == nil)
    }
}

struct GlobalShortcutTests {
    let d: UInt32 = 0x02

    @Test func displaysLikeMacMenus() {
        #expect(KeyCombo(keyCode: d, modifiers: KeyCombo.command | KeyCombo.option | KeyCombo.control).displayString == "⌃⌥⌘D")
        #expect(KeyCombo(keyCode: 0x7A, modifiers: KeyCombo.shift).displayString == "⇧F1")
        #expect(KeyCombo(keyCode: 0x31, modifiers: KeyCombo.control | KeyCombo.option).displayString == "⌃⌥Space")
    }

    @Test func onlySafeCombinationsMayBeGlobal() {
        #expect(KeyCombo(keyCode: d, modifiers: KeyCombo.control | KeyCombo.option).isAllowedGlobally)
        #expect(KeyCombo(keyCode: d, modifiers: KeyCombo.option | KeyCombo.command | KeyCombo.shift).isAllowedGlobally)
        #expect(KeyCombo(keyCode: 0x7A, modifiers: 0).isAllowedGlobally) // F1
        #expect(!KeyCombo(keyCode: d, modifiers: KeyCombo.command).isAllowedGlobally) // ⌘D: every app's
        #expect(!KeyCombo(keyCode: d, modifiers: KeyCombo.command | KeyCombo.shift).isAllowedGlobally)
        #expect(!KeyCombo(keyCode: d, modifiers: KeyCombo.option).isAllowedGlobally) // types ∂
        #expect(!KeyCombo(keyCode: d, modifiers: 0).isAllowedGlobally)
        #expect(!KeyCombo(keyCode: 0x37, modifiers: KeyCombo.control | KeyCombo.option).isAllowedGlobally) // ⌘ key itself
    }

    @Test func settingsKeepShortcutsAndDropUnsafeOrDuplicateOnes() throws {
        let safe = KeyCombo(keyCode: 0x03, modifiers: KeyCombo.control | KeyCombo.option | KeyCombo.command)
        var settings = FluxSettings()
        #expect(settings.globalShortcuts == GlobalShortcutAction.defaults)
        settings.globalShortcuts = [.showFlux: safe, .pauseResumeAll: safe,
                                    .addDownload: KeyCombo(keyCode: d, modifiers: KeyCombo.command)]
        let normalized = settings.normalized()
        #expect(normalized.globalShortcuts == [.showFlux: safe])

        let data = try JSONEncoder().encode(normalized)
        let decoded = try JSONDecoder().decode(FluxSettings.self, from: data)
        #expect(decoded.globalShortcuts == [.showFlux: safe]) // a cleared default stays cleared
        #expect(String(decoding: data, as: UTF8.self).contains("\"showFlux\""))
    }

    @Test func olderSettingsGetTheNewDefaults() throws {
        let old = try JSONDecoder().decode(FluxSettings.self, from: Data(#"{"maxConcurrentDownloads": 2}"#.utf8))
        #expect(old.showInMenuBar && old.notifyWhenFinished && old.notifyOnFailure)
        #expect(old.showDockProgress && old.indexInSpotlight)
        #expect(old.globalShortcuts == GlobalShortcutAction.defaults)
    }
}
