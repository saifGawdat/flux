import Foundation
import Testing
@testable import FluxCore

private func record(_ name: String, url: String = "https://example.com/files/x", size: Int64? = nil,
                    referer: String? = nil) -> DownloadRecord {
    var r = DownloadRecord(url: URL(string: url)!, directory: URL(fileURLWithPath: "/tmp"), fileName: name)
    r.totalBytes = size
    r.referer = referer.flatMap(URL.init(string:))
    return r
}

/// Runs a Python snippet with `-I` (no site packages, no cwd on the path).
private func python(_ code: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-I", "-c", code] + args
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
}

/// Builds a zip from (path in archive, contents) pairs.
private func makeZip(_ entries: [(String, String)], at url: URL) throws {
    let code = """
    import sys, zipfile
    with zipfile.ZipFile(sys.argv[1], "w") as z:
        for i in range(2, len(sys.argv), 2):
            z.writestr(sys.argv[i], sys.argv[i + 1])
    """
    try python(code, [url.path] + entries.flatMap { [$0.0, $0.1] })
}

struct CategoryTests {
    @Test(arguments: [
        ("report.PDF", FileCategory.documents), ("photo.heic", .images), ("clip.mkv", .videos),
        ("song.flac", .music), ("backup.tar.gz", .archives), ("Installer.dmg", .apps), ("README", .other),
        ("weird.xyz", .other),
    ])
    func byExtension(name: String, category: FileCategory) {
        #expect(FileCategory.of(fileName: name) == category)
    }

    @Test func mediaFollowsFormatBeforeANameExists() {
        var audio = DownloadRecord(url: URL(string: "https://youtu.be/x")!, directory: URL(fileURLWithPath: "/tmp"),
                                   kind: .media, mediaFormat: .mp3)
        audio.fileName = "Some Song"
        #expect(audio.category == .music)
        audio.mediaFormat = .mp4_1080
        #expect(audio.category == .videos)
    }
}

struct RuleTests {
    let folder = URL(fileURLWithPath: "/tmp/rules", isDirectory: true)

    @Test func extensionsIncludingDoubleOnes() {
        let rule = DownloadRule(name: "Archives", conditions: [.fileExtension(["zip", ".TAR.GZ"])], folder: folder)
        #expect(rule.matches(record("a.zip")))
        #expect(rule.matches(record("a.tar.gz")))
        #expect(!rule.matches(record("a.gz")))
        #expect(!rule.matches(record("zip")))
    }

    @Test func namePatternIsAGlobIgnoringCase() {
        let rule = DownloadRule(name: "Invoices", conditions: [.namePattern("*invoice*.pdf")], folder: folder)
        #expect(rule.matches(record("March-INVOICE-42.pdf")))
        #expect(!rule.matches(record("invoice.docx")))
    }

    @Test func domainMatchesSubdomainsAndThePageItCameFrom() {
        let rule = DownloadRule(name: "GitHub", conditions: [.domain("https://github.com/")], folder: folder)
        #expect(rule.matches(record("a.zip", url: "https://objects.github.com/x/a.zip")))
        #expect(rule.matches(record("a.png", url: "https://cdn.example.net/a.png", referer: "https://github.com/user/repo")))
        #expect(!rule.matches(record("a.zip", url: "https://notgithub.com/a.zip")))
    }

    @Test func allConditionsMustMatch() {
        let rule = DownloadRule(name: "Big videos", conditions: [.category(.videos), .largerThan(1_000_000_000)], folder: folder)
        #expect(rule.matches(record("movie.mkv", size: 2_000_000_000)))
        #expect(!rule.matches(record("movie.mkv", size: 500_000_000)))
        #expect(!rule.matches(record("disk.iso", size: 2_000_000_000)))
        let small = DownloadRule(name: "Small", conditions: [.smallerThan(1000)], folder: folder)
        #expect(!small.matches(record("unknown.bin")), "unknown size isn't 'smaller than'")
    }

    @Test func linkContainsLooksAtTheWholeLink() {
        let rule = DownloadRule(name: "Work", conditions: [.linkContains("/acme/")], folder: folder)
        #expect(rule.matches(record("q.pdf", url: "https://drive.example.com/ACME/q.pdf")))
    }

    @Test func disabledAndEmptyRulesNeverMatch() {
        #expect(!DownloadRule(name: "x", isEnabled: false, conditions: [.category(.documents)], folder: folder).matches(record("a.pdf")))
        #expect(!DownloadRule(name: "x", conditions: [], folder: folder).matches(record("a.pdf")))
        #expect(!DownloadRule(name: "x", conditions: [.namePattern("  ")], folder: folder).matches(record("a.pdf")))
    }

    @Test func firstMatchingRuleWinsThenCategoryFolders() {
        let downloads = URL(fileURLWithPath: "/Users/me/Downloads", isDirectory: true)
        var settings = FluxSettings(downloadDirectory: downloads)
        #expect(Filing.destination(for: record("a.pdf"), settings: settings) == nil, "nothing on by default")
        settings.sortIntoCategoryFolders = true
        #expect(Filing.destination(for: record("a.pdf"), settings: settings)?.folder == downloads.appendingPathComponent("Documents", isDirectory: true))
        #expect(Filing.destination(for: record("README"), settings: settings) == nil, "Other stays put")
        settings.rules = [
            DownloadRule(name: "Taxes", conditions: [.namePattern("*tax*")], folder: URL(fileURLWithPath: "/a")),
            DownloadRule(name: "PDFs", conditions: [.fileExtension(["pdf"])], folder: URL(fileURLWithPath: "/b")),
        ]
        #expect(Filing.destination(for: record("tax-2026.pdf"), settings: settings) == .init(folder: URL(fileURLWithPath: "/a"), reason: "rule “Taxes”"))
        #expect(Filing.destination(for: record("menu.pdf"), settings: settings)?.folder == URL(fileURLWithPath: "/b"))
    }

    @Test func rulesSurviveSettingsRoundTrip() throws {
        var settings = FluxSettings()
        settings.rules = [DownloadRule(name: "All", conditions: [
            .fileExtension(["a"]), .namePattern("b"), .domain("c"), .linkContains("d"),
            .largerThan(1), .smallerThan(2), .category(.apps),
        ], folder: URL(fileURLWithPath: "/x"))]
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(FluxSettings.self, from: data) == settings)
    }
}

struct ExtractionTests {
    @Test func severalItemsGoIntoAFolderNamedAfterTheArchive() async throws {
        let dir = try tempDir()
        let zip = dir.appendingPathComponent("photos.zip")
        try makeZip([("a.txt", "A"), ("b/c.txt", "C")], at: zip)
        let out = try await ArchiveExtractor.extract(zip, source: URL(string: "https://example.com/photos.zip")!)
        #expect(out.lastPathComponent == "photos")
        #expect(try String(contentsOf: out.appendingPathComponent("b/c.txt"), encoding: .utf8) == "C")
        #expect(getxattr(out.appendingPathComponent("a.txt").path, "com.apple.quarantine", nil, 0, 0, 0) > 0, "extracted files are quarantined")
        #expect(FileManager.default.fileExists(atPath: zip.path), "archive kept")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["photos", "photos.zip"], "no temp folder left")
    }

    @Test func aSingleTopLevelFolderIsPlacedAsIs() async throws {
        let dir = try tempDir()
        let zip = dir.appendingPathComponent("App-1.2.zip")
        try makeZip([("App/one.txt", "1"), ("App/two.txt", "2"), ("__MACOSX/App/._one.txt", "junk")], at: zip)
        let out = try await ArchiveExtractor.extract(zip, source: URL(string: "https://example.com/a.zip")!)
        #expect(out.lastPathComponent == "App")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == ["one.txt", "two.txt"])
    }

    @Test func tarGzAndNeverOverwrites() async throws {
        let dir = try tempDir()
        let src = try tempDir()
        try Data("hello".utf8).write(to: src.appendingPathComponent("notes.txt"))
        let tgz = dir.appendingPathComponent("notes.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", tgz.path, "-C", src.path, "notes.txt"]
        try tar.run()
        tar.waitUntilExit()
        try Data("mine".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let out = try await ArchiveExtractor.extract(tgz, source: URL(string: "https://example.com/n.tgz")!)
        #expect(out.lastPathComponent == "notes (1).txt")
        #expect(try String(contentsOf: dir.appendingPathComponent("notes.txt"), encoding: .utf8) == "mine")
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello")
    }

    @Test func entriesThatClimbOutAreRefused() async throws {
        let parent = try tempDir()
        let dir = parent.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("evil.zip")
        try makeZip([("../escaped.txt", "pwned"), ("ok.txt", "fine")], at: zip)
        _ = try? await ArchiveExtractor.extract(zip, source: URL(string: "https://example.com/evil.zip")!)
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("escaped.txt").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("escaped.txt").path))
    }

    @Test func brokenArchiveReportsAnError() async throws {
        let dir = try tempDir()
        let zip = dir.appendingPathComponent("broken.zip")
        try Data("this is not a zip file".utf8).write(to: zip)
        await #expect(throws: ArchiveExtractor.ExtractError.self) {
            try await ArchiveExtractor.extract(zip, source: URL(string: "https://example.com/b.zip")!)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["broken.zip"])
    }

    @Test func recognizesArchiveNames() {
        #expect(ArchiveExtractor.canExtract(URL(fileURLWithPath: "/a/b.TAR.GZ")))
        #expect(ArchiveExtractor.canExtract(URL(fileURLWithPath: "/a/b.7z")))
        #expect(!ArchiveExtractor.canExtract(URL(fileURLWithPath: "/a/b.gz")))
        #expect(!ArchiveExtractor.canExtract(URL(fileURLWithPath: "/a/.zip")))
        #expect(ArchiveExtractor.baseName(of: URL(fileURLWithPath: "/a/photos.tar.gz")) == "photos")
    }
}

@Suite(.serialized)
struct OrganizeManagerTests {
    private func makeManager(_ change: (inout FluxSettings) -> Void) async throws -> (DownloadManager, URL) {
        let downloads = try tempDir()
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        var settings = FluxSettings(downloadDirectory: downloads)
        change(&settings)
        try await db.save(settings)
        let manager = try await DownloadManager(database: db, jobOptions: fastOptions, mediaTools: .none)
        await manager.start()
        return (manager, downloads)
    }

    private func waitUntilSettled(_ manager: DownloadManager, _ id: UUID) async throws -> DownloadRecord {
        try await eventually("download to finish and settle", timeout: 30) {
            let finishing = await manager.isFinishing(id)
            return await manager.item(id)?.record.status == .completed && !finishing
        }
        return try #require(await manager.item(id)?.record)
    }

    @Test func categoryFoldersSortFinishedDownloads() async throws {
        let server = try TestServer()
        try server.addFile("paper.pdf", size: 10_000)
        let (manager, downloads) = try await makeManager { $0.sortIntoCategoryFolders = true }
        let id = try #require(try await manager.add([.init(url: server.url("paper.pdf"))]).first)
        let done = try await waitUntilSettled(manager, id)
        #expect(done.finalPath == downloads.appendingPathComponent("Documents/paper.pdf"))
        #expect(FileManager.default.fileExists(atPath: try #require(done.finalPath).path))
        #expect(done.filedBy == "Documents")
    }

    @Test func aFolderTheUserChoseIsNeverChanged() async throws {
        let server = try TestServer()
        try server.addFile("paper.pdf", size: 10_000)
        let (manager, _) = try await makeManager { $0.sortIntoCategoryFolders = true }
        let chosen = try tempDir()
        let id = try #require(try await manager.add([.init(url: server.url("paper.pdf"), directory: chosen)]).first)
        let done = try await waitUntilSettled(manager, id)
        #expect(done.finalPath?.deletingLastPathComponent().standardizedFileURL == chosen.standardizedFileURL)
        #expect(done.filedBy == nil)
    }

    @Test func rulesUseTheServersFileName() async throws {
        let server = try TestServer()
        try server.addFile("blob", size: 5_000)
        let invoices = try tempDir().appendingPathComponent("Invoices", isDirectory: true)
        let (manager, _) = try await makeManager {
            $0.rules = [DownloadRule(name: "Invoices", conditions: [.namePattern("invoice-*.pdf")], folder: invoices)]
        }
        // The link says "blob"; Content-Disposition names it invoice-7.pdf.
        let id = try #require(try await manager.add([.init(url: server.url("blob?cd=invoice-7.pdf"))]).first)
        let done = try await waitUntilSettled(manager, id)
        #expect(done.finalPath == invoices.appendingPathComponent("invoice-7.pdf"))
        #expect(done.filedBy == "rule “Invoices”")
    }

    @Test func identicalExistingFileIsFlaggedNotDeleted() async throws {
        let server = try TestServer()
        let data = try server.addFile("setup.dmg", size: 300_000)
        let (manager, downloads) = try await makeManager { _ in }
        // The user already has this file (downloaded with a browser, say).
        try data.write(to: downloads.appendingPathComponent("setup.dmg"))
        let id = try #require(try await manager.add([.init(url: server.url("setup.dmg"))]).first)
        let done = try await waitUntilSettled(manager, id)
        #expect(done.fileName == "setup (1).dmg")
        #expect(done.duplicateOf?.standardizedFileURL == downloads.appendingPathComponent("setup.dmg").standardizedFileURL)
        #expect(done.contentHash == sha256(data))
        #expect(FileManager.default.fileExists(atPath: try #require(done.finalPath).path), "keep both by default")
    }

    @Test func sameSizeDifferentContentIsNotADuplicate() async throws {
        let server = try TestServer()
        try server.addFile("a.bin", size: 50_000)
        let (manager, downloads) = try await makeManager { _ in }
        try Data(repeating: 7, count: 50_000).write(to: downloads.appendingPathComponent("other.bin"))
        let id = try #require(try await manager.add([.init(url: server.url("a.bin"))]).first)
        let done = try await waitUntilSettled(manager, id)
        #expect(done.duplicateOf == nil)
    }

    @Test func archivesAreExtractedWhenAskedTo() async throws {
        let server = try TestServer()
        try makeZip([("docs/readme.txt", "read me"), ("docs/license.txt", "MIT")], at: server.root.appendingPathComponent("docs.zip"))
        let (manager, downloads) = try await makeManager {
            $0.extractArchives = true
            $0.sortIntoCategoryFolders = true
        }
        let id = try #require(try await manager.add([.init(url: server.url("docs.zip"))]).first)
        let done = try await waitUntilSettled(manager, id)
        #expect(done.finalPath == downloads.appendingPathComponent("Archives/docs.zip"), "filed first")
        #expect(done.extractedPath?.path == downloads.appendingPathComponent("Archives/docs").path)
        #expect(done.extractionError == nil)
        #expect(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("Archives/docs/readme.txt").path))
    }

    @Test func failedExtractionKeepsTheDownload() async throws {
        let server = try TestServer()
        try server.addFile("fake.zip", size: 2_000)
        let (manager, _) = try await makeManager { $0.extractArchives = true }
        let id = try #require(try await manager.add([.init(url: server.url("fake.zip"))]).first)
        let done = try await waitUntilSettled(manager, id)
        #expect(done.status == .completed)
        #expect(done.extractionError != nil)
        #expect(FileManager.default.fileExists(atPath: try #require(done.finalPath).path))
    }

    @Test func historyKeepsClearedDownloads() async throws {
        let server = try TestServer()
        try server.addFile("a.txt", size: 100)
        let (manager, _) = try await makeManager { _ in }
        let ids = try await manager.add([.init(url: server.url("a.txt")), .init(url: server.url("a.txt"), startImmediately: false)])
        _ = try await waitUntilSettled(manager, ids[0])

        await manager.archive(ids)
        #expect(await manager.item(ids[0])?.record.isArchived == true)
        #expect(await manager.item(ids[1])?.record.isArchived == false, "unfinished downloads stay in the list")

        try await manager.clearHistory()
        #expect(await manager.item(ids[0]) == nil)
        #expect(await manager.item(ids[1]) != nil)
    }
}
